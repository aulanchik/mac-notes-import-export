#!/usr/bin/env bash
#
# notes-export.sh - export Apple Notes to HTML files (macOS only).
#
# Output layout:
#   <out>/manifest.tsv                      one row per exported note
#   <out>/skipped.tsv                       password-protected notes (cannot be read)
#   <out>/errors.log                        notes that failed to export (only if any)
#   <out>/<Account>/<Folder>/<Note>.html    the note body as HTML
#
# Pipeline:
#   1. list    one osascript (JXA) run builds manifest.tsv using bulk Apple Events
#   2. split   the manifest is cut into batches
#   3. export  N workers (xargs -P), each running osascript on one batch at a time
#   4. report  per-batch logs are merged into a summary and errors.log
#
# Works with the bash 3.2 that ships with macOS (no mapfile, no associative arrays).

set -euo pipefail

readonly PROG="${0##*/}"
readonly DEFAULT_JOBS=4
readonly DEFAULT_BATCH=25

OUT=""
JOBS=$DEFAULT_JOBS
BATCH=$DEFAULT_BATCH
WORK=""          # private temp dir: JS files, batches, per-batch logs
TOTAL=0          # exportable notes found
SKIPPED=0        # password-protected notes
CHUNKS=0         # number of batches
OK=0             # notes exported successfully
POOL_RC=0        # exit status of the worker pool

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
Usage: $PROG [-o output_dir] [-j jobs] [-b batch_size]

Export every readable note from Apple Notes as an HTML file.

  -o DIR   output directory (default: ./notes-export-<timestamp>)
  -j N     parallel workers (default: $DEFAULT_JOBS)
  -b N     notes per worker call (default: $DEFAULT_BATCH)
  -h       show this help
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
  while getopts "o:j:b:h" opt; do
    case "$opt" in
      o) OUT=$OPTARG ;;
      j) JOBS=$OPTARG ;;
      b) BATCH=$OPTARG ;;
      h) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  [[ $# -eq 0 ]]          || die "unexpected argument: $1" 2
  is_positive_int "$JOBS"  || die "-j must be a positive integer" 2
  is_positive_int "$BATCH" || die "-b must be a positive integer" 2
}

prepare_output() {
  [[ -n "$OUT" ]] || OUT="./notes-export-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$OUT"
  OUT="$(cd "$OUT" && pwd)"
  [[ ! -e "$OUT/manifest.tsv" ]] \
    || die "$OUT already contains an export; pick another directory with -o."
}

# ---------------------------------------------------------------------------
# JXA sources. Both scripts share js_common; they are written to $WORK and
# run as files, which avoids passing large scripts through the environment.
#
# manifest.tsv columns (tab-separated):
#   1 id   2 account   3 folder path (levels joined by \x1f)   4 name
#   5 created (ISO 8601)   6 modified (ISO 8601)   7 relative file path
# ---------------------------------------------------------------------------

js_common() {
  cat <<'JS'
ObjC.import('Foundation');

const COL_ID = 0, COL_FILE = 6;

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
JS
}

js_list() {
  cat <<'JS'
// Top-level folders that are not exported. Names are as shown in an English UI.
const SKIP_TOP_LEVEL_FOLDERS = ['Recently Deleted'];
const MAX_NAME_LENGTH = 80;
const MAX_FOLDER_DEPTH = 50;

// A string that is safe to use as one path component.
function safeName(s) {
  let t = String(s).replace(/[\/\\:*?"<>|\u0000-\u001f]/g, '_').trim().replace(/^\.+/, '');
  if (t.length > MAX_NAME_LENGTH) t = t.slice(0, MAX_NAME_LENGTH).trim();
  return t || 'Untitled';
}

// Folders of an account with their parent ids, in one batch of Apple Events.
function readFolders(account) {
  const folders = account.folders().map(f => {
    let parent = null;
    try { parent = f.container().id(); } catch (e) { /* top level */ }
    return { ref: f, id: f.id(), name: f.name(), parent: parent };
  });
  const byId = {};
  folders.forEach(f => { byId[f.id] = f; });
  return { folders: folders, byId: byId };
}

// Folder names from the outermost folder down to `folder`.
function folderPath(folder, byId) {
  const parts = [];
  let cur = folder, guard = 0;
  while (cur && guard++ < MAX_FOLDER_DEPTH) {
    parts.unshift(cur.name);
    cur = byId[cur.parent];   // undefined once the parent is the account
  }
  return parts;
}

// "<dir>/<base>.html", numbered if that path (case-insensitively) is taken.
function uniqueRelPath(dir, base, used) {
  let rel = dir + '/' + base + '.html', n = 2;
  while (used[rel.toLowerCase()]) rel = dir + '/' + base + ' (' + n++ + ').html';
  used[rel.toLowerCase()] = true;
  return rel;
}

function listFolder(accName, folder, parts, state) {
  const notes = folder.ref.notes;
  const ids = notes.id(), names = notes.name();
  const created = notes.creationDate(), modified = notes.modificationDate();
  const locked = notes.passwordProtected();

  const folderCol = parts.map(clean).join('\x1f');
  const dir = [accName].concat(parts).map(safeName).join('/');

  for (let i = 0; i < ids.length; i++) {
    if (state.seen[ids[i]]) continue;
    state.seen[ids[i]] = true;

    if (locked[i]) {
      state.skipped.push([ids[i], accName, folderCol, names[i]].map(clean).join('\t'));
      continue;
    }
    const rel = uniqueRelPath(dir, safeName(names[i]), state.used);
    state.manifest.push([ids[i], clean(accName), folderCol, clean(names[i]),
                         created[i].toISOString(), modified[i].toISOString(), rel].join('\t'));
  }
}

function run(argv) {
  const manifestPath = argv[0], skippedPath = argv[1];
  const state = { manifest: [], skipped: [], used: {}, seen: {} };

  for (const account of Application('Notes').accounts()) {
    const accName = account.name();
    const tree = readFolders(account);
    for (const folder of tree.folders) {
      const parts = folderPath(folder, tree.byId);
      if (SKIP_TOP_LEVEL_FOLDERS.indexOf(parts[0]) !== -1) continue;
      listFolder(accName, folder, parts, state);
    }
  }
  writeFile(manifestPath, lines(state.manifest));
  writeFile(skippedPath, lines(state.skipped));
}
JS
}

js_export() {
  cat <<'JS'
// argv: <batch file> <output dir> <log file>
function run(argv) {
  const batchPath = argv[0], outDir = argv[1], logPath = argv[2];
  const Notes = Application('Notes');
  const log = [];

  for (const line of readFile(batchPath).split('\n')) {
    if (!line) continue;
    const cols = line.split('\t');
    const rel = cols[COL_FILE];
    try {
      writeFile(outDir + '/' + rel, Notes.notes.byId(cols[COL_ID]).body());
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
  { cat "$WORK/common.js"; js_list;   } > "$WORK/list.js"
  { cat "$WORK/common.js"; js_export; } > "$WORK/export.js"
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

list_notes() {
  log "Listing notes (macOS may ask to let this terminal control Notes)..."
  osascript -l JavaScript "$WORK/list.js" "$OUT/manifest.tsv" "$OUT/skipped.tsv" \
    || die "could not list notes; check System Settings > Privacy & Security > Automation."

  TOTAL="$(count_lines "$OUT/manifest.tsv")"
  SKIPPED="$(count_lines "$OUT/skipped.tsv")"
  log "Found $TOTAL exportable notes ($SKIPPED password-protected, skipped)."
}

# Create every target directory up front so that workers only write files.
make_output_dirs() {
  ( cd "$OUT" \
    && cut -f7 manifest.tsv | sed 's|/[^/]*$||' | sort -u | tr '\n' '\0' \
    | xargs -0 mkdir -p -- )
}

split_manifest() {
  mkdir -p "$WORK/chunks" "$WORK/logs" "$WORK/done"
  split -a 4 -l "$BATCH" "$OUT/manifest.tsv" "$WORK/chunks/"
  CHUNKS="$(ls "$WORK/chunks" | wc -l | tr -d ' ')"
}

# Runs in a child bash (see run_workers): export one batch, then print progress.
export_chunk() {
  local chunk=$1 name=${1##*/} rc=0 finished
  osascript -l JavaScript "$WORK/export.js" "$chunk" "$OUT" "$WORK/logs/$name.log" || rc=$?
  : > "$WORK/done/$name"
  finished="$(ls "$WORK/done" | wc -l | tr -d ' ')"
  printf '  batch %s/%s done\n' "$finished" "$CHUNKS" >&2
  return "$rc"
}

run_workers() {
  log "Exporting with $JOBS workers ($CHUNKS batches of up to $BATCH notes)..."
  export WORK OUT CHUNKS
  export -f export_chunk
  POOL_RC=0
  # "$BASH" is this very interpreter, so the exported function parses the same way.
  printf '%s\0' "$WORK"/chunks/* \
    | xargs -0 -n 1 -P "$JOBS" "$BASH" -c 'export_chunk "$1"' _ || POOL_RC=$?
}

# Merge per-batch logs. A batch with no log means its worker died, so all of
# its notes are counted as failed.
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
  grep '^ERR' "$results" > "$OUT/errors.log" || true
  [[ -s "$OUT/errors.log" ]] || rm -f "$OUT/errors.log"
}

report() {
  log
  log "Exported $OK of $TOTAL notes to: $OUT"
  if [[ -f "$OUT/errors.log" ]]; then
    log "Some notes failed - see $OUT/errors.log"
  fi
  if [[ "$SKIPPED" -gt 0 ]]; then
    log "Password-protected notes are listed in $OUT/skipped.tsv"
  fi
  if [[ "$POOL_RC" -ne 0 || "$OK" -ne "$TOTAL" ]]; then
    return 1
  fi
}

main() {
  require_macos
  parse_args "$@"
  prepare_output

  WORK="$(mktemp -d)"
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  write_js_files

  list_notes
  [[ "$TOTAL" -gt 0 ]] || return 0

  make_output_dirs
  split_manifest
  run_workers
  collect_results
  report
}

# Run only when executed, so the functions can be sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
