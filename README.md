# Apple Notes export / import

Two small shell scripts that move notes out of and back into **Apple Notes**, in
parallel. macOS only.

| Script                               | What it does                                                       |
| ------------------------------------ | ------------------------------------------------------------------ |
| [`notes-export.sh`](#notes-exportsh) | Exports every readable note to an HTML file plus a `manifest.tsv`. |
| [`notes-import.sh`](#notes-importsh) | Recreates folders and notes in Apple Notes from such an export.    |

```bash
./notes-export.sh -o ~/notes-backup          # export
./notes-import.sh -a iCloud ~/notes-backup   # import into iCloud
```

## Requirements

- macOS. Both scripts exit immediately on any other OS.
- The stock `/bin/bash` (3.2) is enough; nothing needs to be installed.
- Automation permission. On the first run macOS asks whether your terminal may
  control **Notes**. Click **OK**. If you declined by mistake, re-enable it in
  _System Settings > Privacy & Security > Automation_.

## How both scripts work

Both follow the same pipeline, and talk to Notes through `osascript`
(JavaScript for Automation):

1. A single `osascript` run does the sequential part (listing notes, or
   creating folders).
2. The manifest is split into batches of `-b` notes.
3. `xargs -P` keeps `-j` workers running. Each worker is one `osascript`
   process that handles one whole batch, so process start-up is paid once per
   batch rather than once per note.
4. Per-batch logs are merged into a summary. A batch whose worker died without
   writing a log has all its notes counted as failed. The temp directory is
   removed, also on Ctrl-C.

Notes handles Apple Events mostly one at a time, so concurrency mainly hides
start-up and file-writing cost. The defaults (`-j 4`, `-b 25`) are a sensible
starting point.

- Raising `-j` far beyond 4 usually gives little and can cause Apple Event
  timeouts. If you see timeouts, lower it.
- Larger `-b` means fewer process launches; smaller `-b` means less lost work
  if a worker dies. Failures are reported per batch.

---

# notes-export.sh

Export every readable note from Apple Notes to plain HTML files.

## Usage

```
notes-export.sh [-o output_dir] [-j jobs] [-b batch_size]
```

| Option   | Default                      | Meaning                                                                   |
| -------- | ---------------------------- | ------------------------------------------------------------------------- |
| `-o DIR` | `./notes-export-<timestamp>` | Output directory. Created if missing. Must not already contain an export. |
| `-j N`   | `4`                          | Number of parallel workers.                                               |
| `-b N`   | `25`                         | Notes handled per worker call.                                            |
| `-h`     |                              | Show help.                                                                |

Exit status: `0` if every note was exported, `1` if any note failed or the
worker pool failed, `2` for bad arguments.

## Output

```
<out>/
├── manifest.tsv                 one row per exported note
├── skipped.tsv                  password-protected notes that were not exported
├── errors.log                   only present if some notes failed
└── <Account>/<Folder>/.../<Note>.html
```

- Each note becomes one HTML file holding the note body exactly as Notes
  returns it. Nested folders become nested directories.
- File names are made filesystem-safe (`/ \ : * ? " < > |` and control
  characters become `_`, names are cut to 80 characters). Notes that end up with
  the same path get ` (2)`, ` (3)`, ... appended, comparing case-insensitively.
- Notes in _Recently Deleted_ are not exported.

### manifest.tsv

Tab-separated, no header, UTF-8. `notes-import.sh` reads this file.

| #   | Column      | Notes                                                |
| --- | ----------- | ---------------------------------------------------- |
| 1   | id          | Notes' internal id (`x-coredata://...`)              |
| 2   | account     | e.g. `iCloud`, `On My Mac`                           |
| 3   | folder path | levels joined with the ASCII unit separator (`\x1f`) |
| 4   | name        | original note name                                   |
| 5   | created     | ISO 8601, UTC                                        |
| 6   | modified    | ISO 8601, UTC                                        |
| 7   | file        | path relative to the output directory                |

`skipped.tsv` has the columns id, account, folder path, name.
`errors.log` lines look like `ERR<TAB>file<TAB>reason`.

## Export steps

1. **List.** One `osascript` run reads all accounts, folders and note
   properties with a few bulk Apple Events per folder, and writes
   `manifest.tsv` and `skipped.tsv`.
2. **Prepare.** All target directories are created up front, so workers only
   write files.
3. **Export.** Each worker reads the body of every note in its batch and writes
   the HTML files.
4. **Report.** The summary and `errors.log` are written.

## Export limitations

- **Password-protected notes** cannot be read through the scripting interface.
  They are listed in `skipped.tsv`. To include them, remove the lock in Notes
  first (_Note > Remove Lock_), export, then re-lock. Keep the export folder
  somewhere safe in the meantime.
- **Attachments**: images embedded in the HTML are kept. Other attachments
  (PDFs, scans, drawings, files) are not available through scripting and are
  not exported.
- **Empty folders** are not exported, since the output is organised by note.
- **Recently Deleted** is matched by its English name. On a Mac running Notes
  in another language, that folder is exported like any other.
- **Dates** are recorded in `manifest.tsv` only; the HTML files get the
  export time as their modification time.
- Two folders whose names differ only by characters that are replaced in file
  names (for example `a/b` and `a_b`) are merged into one directory. File names
  stay unique.

## Export troubleshooting

| Symptom                                     | Cause / fix                                                                                                             |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `this script only runs on macOS`            | Run it on a Mac.                                                                                                        |
| `could not list notes`                      | Allow your terminal under _Automation_ for Notes, and make sure Notes can open.                                         |
| `already contains an export`                | Pass a new `-o` directory (the script will not mix two exports).                                                        |
| Some notes in `errors.log`                  | Re-run into a new directory; if the same notes fail, open them in Notes to check they are not corrupt or still syncing. |
| `worker failed before finishing this batch` | An `osascript` process crashed or timed out. Retry with a lower `-j`.                                                   |

---

# notes-import.sh

Import notes exported by `notes-export.sh` into Apple Notes.

## Usage

```
notes-import.sh [-a account] [-j jobs] [-b batch_size] [-p] [-y] <export-dir>
```

| Option         | Default         | Meaning                                                                                                     |
| -------------- | --------------- | ----------------------------------------------------------------------------------------------------------- |
| `<export-dir>` | required        | Directory produced by `notes-export.sh`. Must contain `manifest.tsv` and the HTML files it lists, in place. |
| `-a NAME`      | default account | Target Notes account, spelled as in Notes, e.g. `iCloud` or `On My Mac`.                                    |
| `-j N`         | `4`             | Number of parallel workers.                                                                                 |
| `-b N`         | `25`            | Notes handled per worker call.                                                                              |
| `-p`           | off             | Put each source account's folders under a top-level folder named after that account.                        |
| `-y`           | off             | Do not ask for confirmation.                                                                                |
| `-h`           |                 | Show help.                                                                                                  |

Unless you pass `-y`, the script shows how many notes it will import and where,
and waits for `y`. If it has no terminal to ask on (for example in a cron job),
it stops and tells you to use `-y`.

Exit status: `0` if every note was imported, `1` if any note failed, the worker
pool failed, or you declined the prompt, `2` for bad arguments.

## What ends up where

- **One target account.** Everything goes into the account given with `-a`, or
  into your default account. The script imports into one account per run, so an
  export with several accounts is merged into that one. Folders with the
  same path then share a folder (the `Notes` folder of `iCloud` and the
  `Notes` folder of `On My Mac` both become `Notes`). Use `-p` to keep them
  apart:

  ```
  without -p                  with -p
  Notes/                      iCloud/Notes/
  Work/Sub/                   iCloud/Work/Sub/
                              On My Mac/Notes/
  ```

- **Folders are reused, not duplicated.** A folder that already exists at the
  same place with the same name (case-sensitive) receives the notes. Missing
  folders, including nested ones, are created.
- **Titles.** Notes takes each note's title from the first line of its body.
  The names in `manifest.tsv` are not used when importing.
- **`import-errors.log`** is written into the export directory if any note
  failed. Lines look like `ERR<TAB>file<TAB>reason`.

## Import steps

1. **Folders.** One `osascript` run finds or creates every folder the manifest
   needs, one at a time. This is done once, up front, so that parallel workers
   cannot create the same folder twice.
2. **Split.** The manifest is cut into batches.
3. **Import.** Each worker looks up all folders once, then reads each HTML file
   in its batch and creates the note in the right folder. Workers never create
   folders; a missing one is reported as an error for that note.
4. **Report.** The summary and `import-errors.log` are written.

## Import limitations

- **No duplicate detection.** Importing the same export twice creates every
  note twice. After a partial failure, do not simply run the whole import
  again (see _Retrying failed notes_ below).
- **Dates are not restored.** Imported notes get the import time as created
  and modified date; the original dates stay in `manifest.tsv`.
- **Locks and unsupported attachments** are not restored, because they were
  not exported. Notes that were locked when you exported are not in the export
  at all.
- **Formatting** is whatever Notes makes of the HTML. Expect it to match for
  ordinary text, lists, tables and embedded images, but not to be identical in
  every detail.
- **Empty folders** from the original are not recreated.
- **Keep the export directory intact.** The importer opens each file by the
  relative path in `manifest.tsv`. Renaming or moving files breaks those notes.

## Retrying failed notes

A worker that dies mid-batch may already have created some of that batch's
notes, so check the target folders before retrying. To import only the notes
listed in `import-errors.log`, build a small export directory that points at
the same files, then import it:

```bash
EXPORT=~/notes-backup
mkdir ~/notes-retry
cut -f2 "$EXPORT/import-errors.log" | sort > ~/notes-retry/failed.txt
awk -F'\t' 'NR==FNR { f[$0]=1; next } ($7 in f)' \
    ~/notes-retry/failed.txt "$EXPORT/manifest.tsv" > ~/notes-retry/manifest.tsv
for d in "$EXPORT"/*/; do ln -s "${d%/}" ~/notes-retry/; done
./notes-import.sh -a iCloud ~/notes-retry
```

## Import troubleshooting

| Symptom                                                     | Cause / fix                                                                                                                            |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `this script only runs on macOS`                            | Run it on a Mac.                                                                                                                       |
| `is missing or empty; is this a notes-export.sh directory?` | Point the script at the directory that contains `manifest.tsv`, not at a parent or an HTML subfolder.                                  |
| `could not prepare folders`                                 | Wrong account name for `-a` (check the spelling in Notes), or the Automation permission is missing.                                    |
| `no terminal to ask for confirmation`                       | Pass `-y` when running without a terminal.                                                                                             |
| `cannot read <file>` in `import-errors.log`                 | The file named in the manifest is missing. For example the note failed during export (see `errors.log` there) or the files were moved. |
| `folder not found: ...`                                     | A folder could not be created or was renamed in Notes while the import was running. Retry only those notes.                            |
| `worker failed before finishing this batch`                 | An `osascript` process crashed or timed out. Check for partly imported notes, then retry with a lower `-j`.                            |
