# mac-notes-import-export

# notes-export.sh

Export every readable note from **Apple Notes** to plain HTML files, in parallel.
macOS only.

```bash
./notes-export.sh -o ~/notes-backup
```

## Requirements

- macOS. The script exits immediately on any other OS.
- The stock `/bin/bash` (3.2) is enough; nothing needs to be installed.
- Automation permission. On the first run macOS asks whether your terminal may
  control **Notes**. Click **OK**. If you declined by mistake, re-enable it in
  _System Settings > Privacy & Security > Automation_.

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

Tab-separated, no header, UTF-8:

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

## How it works

1. **List.** One `osascript` (JavaScript for Automation) run reads all accounts,
   folders and note properties with a few bulk Apple Events per folder, and
   writes `manifest.tsv` and `skipped.tsv`.
2. **Prepare.** All target directories are created up front, and the manifest
   is split into batches of `-b` notes.
3. **Export.** `xargs -P` keeps `-j` workers running. Each worker is one
   `osascript` process that reads the body of every note in its batch and
   writes the HTML files, so you pay process start-up once per batch rather
   than once per note.
4. **Report.** Per-batch logs are merged. A batch whose worker died without
   writing a log has all its notes counted as failed. The summary and
   `errors.log` are written, and the temp directory is removed.

### Tuning

Notes processes Apple Events mostly one at a time, so concurrency mainly hides
start-up and file-writing cost. The defaults are a sensible starting point.

- Raising `-j` far beyond 4 usually gives little and can cause Apple Event
  timeouts. If you see timeouts, lower it.
- Larger `-b` means fewer process launches; smaller `-b` means less lost work
  if a worker dies. Failures are reported per batch.

## Limitations

- **Password-protected notes** cannot be read through the scripting interface.
  They are listed in `skipped.tsv`. To include them, remove the lock in Notes
  first (_Note > Remove Lock_), export, then re-lock. Keep the export folder
  somewhere safe in the meantime.
- **Attachments**: images embedded in the HTML are kept. Other attachments
  (PDFs, scans, drawings, files) are not available through scripting and are
  not exported.
- **Empty folders** are not recreated, since the output is organised by note.
- **Recently Deleted** is matched by its English name. On a Mac running Notes
  in another language, that folder is exported like any other.
- **Dates** are recorded in `manifest.tsv` only; the HTML files get the
  export time as their modification time.
- Two folders whose names differ only by characters that are replaced in file
  names (for example `a/b` and `a_b`) are merged into one directory. File names
  stay unique.

## Troubleshooting

| Symptom                                     | Cause / fix                                                                                                             |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `this script only runs on macOS`            | Run it on a Mac.                                                                                                        |
| `could not list notes`                      | Allow your terminal under _Automation_ for Notes, and make sure Notes can open.                                         |
| `already contains an export`                | Pass a new `-o` directory (the script will not mix two exports).                                                        |
| Some notes in `errors.log`                  | Re-run into a new directory; if the same notes fail, open them in Notes to check they are not corrupt or still syncing. |
| `worker failed before finishing this batch` | An `osascript` process crashed or timed out. Retry with a lower `-j`.                                                   |

## Importing again

The companion script `notes-import.sh` reads the same `manifest.tsv` and
HTML files to recreate the notes in Apple Notes.
