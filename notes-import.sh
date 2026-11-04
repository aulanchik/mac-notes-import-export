#!/usr/bin/env bash
#
# notes-import.sh - import notes exported by notes-export.sh into Apple Notes
# (macOS only).
#
# Input: an export directory containing manifest.tsv and the HTML files it lists.
#
# Pipeline:
#   1. folders  one osascript (JXA) run finds or creates every folder the notes
#               need, sequentially, so workers never race to create the same one
#   2. split    the manifest is cut into batches
#   3. import   N workers (xargs -P), each running osascript on one batch at a time
#   4. report   per-batch logs are merged into a summary and import-errors.log
#
# Existing folders are reused and notes are added to them. Nothing is checked
# for duplicates, so importing the same export twice creates every note twice.
#
# Works with the bash 3.2 that ships with macOS (no mapfile, no associative arrays).

set -euo pipefail

readonly PROG="${0##*/}"
readonly DEFAULT_JOBS=4
readonly DEFAULT_BATCH=25

ACCOUNT=""        # target account name; empty means the default account
ACCOUNT_ARG="-"   # what the JS receives ("-" = default; argv cannot carry nil)
JOBS=$DEFAULT_JOBS
BATCH=$DEFAULT_BATCH
PREFIX=0          # 1 = put each source account's folders under a folder of that name
ASSUME_YES=0
IN=""             # export directory (absolute)
MANIFEST=""
TARGET_LABEL=""   # for messages
WORK=""           # private temp dir: JS files, batches, per-batch logs
TOTAL=0           # notes to import
CHUNKS=0          # number of batches
OK=0              # notes imported successfully
POOL_RC=0         # exit status of the worker pool

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

is_positive_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# Line count of a file, stripped of the padding BSD wc adds. 0 if it is missing.
count_lines() {
  [[ -f "$1" ]] || { echo 0; return; }
  wc -l < "$1" | tr -d ' '
}

cleanup() { [[ -z "$WORK" ]] || rm -rf "$WORK"; }

usage() {
  cat <<EOF
Usage: $PROG [-a account] [-j jobs] [-b batch_size] [-p] [-y] <export-dir>

Import notes exported by notes-export.sh into Apple Notes.

  -a NAME  target Notes account, e.g. "iCloud" (default: your default account)
  -j N     parallel workers (default: $DEFAULT_JOBS)
  -b N     notes per worker call (default: $DEFAULT_BATCH)
  -p       put each source account's folders under a top-level folder named
           after that account (useful when the export has several accounts)
  -y       do not ask for confirmation
  -h       show this help

Note: importing the same export twice creates duplicate notes.
EOF
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] \
    || die "this script only runs on macOS (detected: $(uname -s))."
  command -v osascript >/dev/null 2>&1 || die "osascript not found."
}

parse_args() {
  local opt
  OPTIND=1
  while getopts "a:j:b:pyh" opt; do
    case "$opt" in
      a) ACCOUNT=$OPTARG ;;
      j) JOBS=$OPTARG ;;
      b) BATCH=$OPTARG ;;
      p) PREFIX=1 ;;
      y) ASSUME_YES=1 ;;
      h) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  [[ $# -eq 1 ]]           || { usage >&2; exit 2; }
  is_positive_int "$JOBS"  || die "-j must be a positive integer" 2
  is_positive_int "$BATCH" || die "-b must be a positive integer" 2

  IN="$1"
  ACCOUNT_ARG="${ACCOUNT:--}"
  TARGET_LABEL="${ACCOUNT:-your default Notes account}"
}

validate_input() {
  [[ -d "$IN" ]] || die "not a directory: $IN"
  IN="$(cd "$IN" && pwd)"
  MANIFEST="$IN/manifest.tsv"
  [[ -s "$MANIFEST" ]] \
    || die "$MANIFEST is missing or empty; is this a notes-export.sh directory?"
  TOTAL="$(count_lines "$MANIFEST")"
}

confirm() {
  [[ "$ASSUME_YES" -ne 1 ]] || return 0
  local reply
  read -r -p "Import $TOTAL notes into $TARGET_LABEL? [y/N] " reply \
    || die "no terminal to ask for confirmation; pass -y to proceed."
  if [[ "$reply" != [yY] && "$reply" != [yY][eE][sS] ]]; then
    log "Aborted."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# JXA sources. All scripts share js_common; they are written to $WORK and run
# as files, which avoids passing large scripts through the environment.
#
# manifest.tsv columns (tab-separated), as written by notes-export.sh:
#   1 id   2 account   3 folder path (levels joined by \x1f)   4 name
#   5 created   6 modified   7 relative file path
# ---------------------------------------------------------------------------

js_common() {
  cat <<'JS'
ObjC.import('Foundation');

const COL_ACCOUNT = 1, COL_FOLDER = 2, COL_FILE = 6;
const FOLDER_SEP = '\x1f';

// Tabs and newlines would break the TSV format.
const clean = s => String(s).replace(/[\t\r\n]+/g, ' ');

function writeFile(path, text) {
  const ok = $.NSString.stringWithString(text)
    .writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  if (!ok) throw new Error('cannot write ' + path);
}

function readFile(path) {
  const s = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
    path, $.NSUTF8StringEncoding, null));
  if (typeof s !== 'string') throw new Error('cannot read ' + path);
  return s;
}

const lines = rows => rows.length ? rows.join('\n') + '\n' : '';

// Manifest or batch file -> array of column arrays.
const readRows = path => readFile(path).split('\n').filter(l => l.length).map(l => l.split('\t'));

// Target account: the named one, or the default account when name is "-".
function getAccount(Notes, name) {
  const account = name !== '-' ? Notes.accounts.byName(name) : Notes.defaultAccount();
  account.name();   // throws if the account does not exist
  return account;
}

// Folder names a note is imported under, outermost first.
function folderParts(cols, prefix) {
  const parts = cols[COL_FOLDER].split(FOLDER_SEP);
  return prefix === '1' ? [cols[COL_ACCOUNT]].concat(parts) : parts;
}
JS
}

js_folders() {
  cat <<'JS'
// Direct child folder called `name` of `parent` (or of the account if null).
function childFolder(account, parent, name) {
  const parentId = parent ? parent.id() : account.id();
  const candidates = parent ? parent.folders() : account.folders();
  for (const f of candidates) {
    if (clean(f.name()) !== name) continue;
    let containerId = parentId;
    try { containerId = f.container().id(); } catch (e) { /* assume a direct child */ }
    if (containerId === parentId) return f;
  }
  return null;
}

// Find or create the folder at path `parts`; returns the innermost folder.
function ensureFolder(Notes, account, parts, cache) {
  let parent = null, key = '';
  for (const name of parts) {
    key += FOLDER_SEP + name;
    if (cache[key]) { parent = cache[key]; continue; }

    let folder = childFolder(account, parent, name);
    if (!folder) {
      (parent ? parent.folders : account.folders).push(Notes.Folder({ name: name }));
      folder = childFolder(account, parent, name);
      if (!folder) throw new Error('could not create folder "' + name + '"');
    }
    cache[key] = parent = folder;
  }
  return parent;
}

// argv: <manifest> <account or -> <prefix 0|1>
function run(argv) {
  const manifestPath = argv[0], accountName = argv[1], prefix = argv[2];
  const Notes = Application('Notes');
  const account = getAccount(Notes, accountName);
  const cache = {}, seen = {};

  for (const cols of readRows(manifestPath)) {
    const parts = folderParts(cols, prefix);
    const key = parts.join(FOLDER_SEP);
    if (seen[key]) continue;
    seen[key] = true;
    ensureFolder(Notes, account, parts, cache);
  }
}
JS
}

js_import() {
  cat <<'JS'
// Every folder of the account, keyed by its path (names joined by FOLDER_SEP).
// Built once per worker, so looking up a note's folder costs no Apple Events.
function folderIndex(account) {
  const folders = account.folders().map(f => {
    let parent = null;
    try { parent = f.container().id(); } catch (e) { /* top level */ }
    return { ref: f, id: f.id(), name: clean(f.name()), parent: parent };
  });
  const byId = {};
  folders.forEach(f => { byId[f.id] = f; });

  const index = {};
  for (const folder of folders) {
    const parts = [];
    let cur = folder, guard = 0;
    while (cur && guard++ < 50) {
      parts.unshift(cur.name);
      cur = byId[cur.parent];   // undefined once the parent is the account
    }
    const key = parts.join(FOLDER_SEP);
    if (!index[key]) index[key] = folder.ref;
  }
  return index;
}

// argv: <batch file> <export dir> <account or -> <prefix 0|1> <log file>
// Workers never create folders; the folders step already did.
function run(argv) {
  const batchPath = argv[0], inDir = argv[1], accountName = argv[2];
  const prefix = argv[3], logPath = argv[4];
  const Notes = Application('Notes');
  const index = folderIndex(getAccount(Notes, accountName));
  const log = [];

  for (const cols of readRows(batchPath)) {
    const rel = cols[COL_FILE];
    try {
      const parts = folderParts(cols, prefix);
      const folder = index[parts.join(FOLDER_SEP)];
      if (!folder) throw new Error('folder not found: ' + parts.join(' / '));
      folder.notes.push(Notes.Note({ body: readFile(inDir + '/' + rel) }));
      log.push('OK\t' + rel);
    } catch (e) {
      log.push('ERR\t' + rel + '\t' + clean(e.message || e));
    }
  }
  writeFile(logPath, lines(log));
}
JS
}

write_js_files() {
  js_common > "$WORK/common.js"
  { cat "$WORK/common.js"; js_folders; } > "$WORK/folders.js"
  { cat "$WORK/common.js"; js_import;  } > "$WORK/import.js"
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

create_folders() {
  log "Preparing folders in $TARGET_LABEL (macOS may ask to let this terminal control Notes)..."
  osascript -l JavaScript "$WORK/folders.js" "$MANIFEST" "$ACCOUNT_ARG" "$PREFIX" \
    || die "could not prepare folders; check the account name (-a) and System Settings > Privacy & Security > Automation."
}

split_manifest() {
  mkdir -p "$WORK/chunks" "$WORK/logs" "$WORK/done"
  split -a 4 -l "$BATCH" "$MANIFEST" "$WORK/chunks/"
  CHUNKS="$(ls "$WORK/chunks" | wc -l | tr -d ' ')"
}

# Runs in a child bash (see run_workers): import one batch, then print progress.
import_chunk() {
  local chunk=$1 name=${1##*/} rc=0 finished
  osascript -l JavaScript "$WORK/import.js" "$chunk" "$IN" "$ACCOUNT_ARG" "$PREFIX" \
    "$WORK/logs/$name.log" || rc=$?
  : > "$WORK/done/$name"
  finished="$(ls "$WORK/done" | wc -l | tr -d ' ')"
  printf '  batch %s/%s done\n' "$finished" "$CHUNKS" >&2
  return "$rc"
}

run_workers() {
  log "Importing $TOTAL notes with $JOBS workers ($CHUNKS batches of up to $BATCH notes)..."
  export WORK IN ACCOUNT_ARG PREFIX CHUNKS
  export -f import_chunk
  POOL_RC=0
  # "$BASH" is this very interpreter, so the exported function parses the same way.
  printf '%s\0' "$WORK"/chunks/* \
    | xargs -0 -n 1 -P "$JOBS" "$BASH" -c 'import_chunk "$1"' _ || POOL_RC=$?
}

# Merge per-batch logs. A batch with no log means its worker died, so all of
# its notes are counted as failed (some of them may nevertheless have been
# created before the crash).
collect_results() {
  local results="$WORK/results.log" chunk name
  : > "$results"
  for chunk in "$WORK"/chunks/*; do
    name=${chunk##*/}
    if [[ -f "$WORK/logs/$name.log" ]]; then
      cat "$WORK/logs/$name.log" >> "$results"
    else
      awk -F'\t' '{ print "ERR\t" $7 "\tworker failed before finishing this batch" }' \
        "$chunk" >> "$results"
    fi
  done

  OK="$(grep -c '^OK' "$results" || true)"
  grep '^ERR' "$results" > "$IN/import-errors.log" || true
  [[ -s "$IN/import-errors.log" ]] || rm -f "$IN/import-errors.log"
}

report() {
  log
  log "Imported $OK of $TOTAL notes into $TARGET_LABEL."
  if [[ -f "$IN/import-errors.log" ]]; then
    log "Some notes failed - see $IN/import-errors.log"
  fi
  if [[ "$POOL_RC" -ne 0 || "$OK" -ne "$TOTAL" ]]; then
    return 1
  fi
}

main() {
  require_macos
  parse_args "$@"
  validate_input
  confirm

  WORK="$(mktemp -d)"
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  write_js_files

  create_folders
  split_manifest
  run_workers
  collect_results
  report
}

# Run only when executed, so the functions can be sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
