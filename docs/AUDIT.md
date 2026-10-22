# Pre-release audit

**English** · [Русский](AUDIT.ru.md)

October 21, 2026. Three independent code reviews (security; data safety; the editor and extensions), a build from a clean copy of the repository, and a run of every automated check. Each finding was confirmed by reading the code or reproducing it. Below: what was fixed and what remains.

## Fixed

### Security

| Before | After |
|---|---|
| Clicking a link in someone else’s note launched a program, script or `.app` without asking (`[report](run.command)`); `ssh:`, `smb:` and other apps’ URL schemes opened right away | Programs, scripts and bundles are only revealed in Finder; links other than http, https and mailto ask first |
| ENEX import pulled the contents of any local file into a note through external XML entities (XXE) | External entities are never loaded |
| HTML export embedded any local file a note linked to (`![](~/.ssh/id_rsa)`) | Only pictures are embedded |
| PDF and printing: raw HTML (`<iframe>`) read any file on disk into the document, and pictures were loaded from the network | The export page gets pictures and the document itself; everything else, network included, is blocked |
| The editor’s “notes never reach the network” rule never compiled (WebKit content-blocker patterns have no `\|`), so remote pictures were loaded | The rule is fixed; a Content-Security-Policy on the editor page is a second line of defense |
| The test control channel (running JS and actions from JSON files) shipped in the regular build; Hardened Runtime was off | The channel is only in the build for automated checks (`PERO_TEST_HOOKS=1`); Hardened Runtime is on; Web Inspector only in the test build |
| `pero://new?folder=../../..`, a folder from Share or from Shortcuts could create a file outside the library; file names from Share were not checked | Paths that leave the library are rejected |
| Importing `.md` copied any files referenced by picture links into the library | Only pictures are copied |
| The locked-notes key was stored in the keychain even on Macs without Touch ID | Stored only where Touch ID exists and is turned on |
| Words of a locked note stayed in the search-index file | `secure_delete` in the index |
| The decryption script echoed the password | The password isn’t echoed |

### Data safety

| Before | After |
|---|---|
| An open note that was deleted stayed in memory; a new note with the same name then opened with the old text and overwrote its own | The session of a vanished note is closed and never writes again |
| Separate note windows and Quick Note didn’t pick up changes on disk, and after a move, deletion or locking could write old text back (including as plain text next to the encrypted file) | All open notes follow the disk in one place (`SessionStore`) |
| Convert to Smart Folder deleted the whole folder, pictures and other files included | The folder is removed only if nothing is left in it |
| Moving a folder broke every relative link inside it; so did moving several notes that link to each other | Links to what moves follow it (unit tests) |
| A Windows-1251 note couldn’t be saved after typing an emoji; in separate windows silently, losing the edits | The note switches to UTF-8 |
| A symlinked note couldn’t be saved | The write goes to the file the link points to |
| An unreadable `state.json` was silently replaced with an empty one (losing pins and smart folders); its trash entries were used as paths (`"../.."` deleted the library) | An unreadable file is set aside; trash entries are validated |
| A cleared title turned `[[Title]]` links in other notes into `[[]]` | An empty title leaves links alone |
| Lock Note right after editing the title did nothing | The renamed file is locked |
| An existing note that was emptied was deleted for good (also in folders from disk) | It goes to Recently Deleted; only a new blank note vanishes |
| Changing only the letter case of a title produced “Hello 2.md” | Renamed in place |
| Two deleted notes with the same path were restored and deleted together | Actions apply to one |
| The library could be moved into its own subfolder | Not allowed |

### Editor

- An empty `<u></u>`, `[](url)`, `[[Note|]]`, and links or pictures broken across a line took down the formatting of the whole note.
- Paragraph styles rewrote code inside code blocks and front matter; Monostyled merged neighboring code blocks; ⌘0–⌘6 behaved differently from the menu.
- Checklist sorting pulled items out from under their parent and could run in a different note.
- The `>>` suggestion ate text in nested quotes and in code.
- Resizing a picture broke `<…>` destinations and dropped the title.
- The text of a decrypted locked note stayed in the page cache after closing.
- Placeholders of pasted pictures could get mixed up; SVG and WebP were saved as `.jpg`.
- Tables: Enter in a header-only table, Tab from the last cell, inserting a column left or right without outer `|`.
- Pasted code containing ```` ``` ```` escaped its block; Quick Look no longer loads pictures from the network.
- Sharing two files with the same name no longer fails.

### Repository

- No personal data: names, paths, team and certificate IDs. The signing team is found at build time; the App Group is `$(TeamIdentifierPrefix)local.pero`.
- `.gitignore`; a build from a clean copy works, and the editor page rebuilds byte for byte.
- Unlicense; the licenses of third-party libraries are collected at build time.
- The format of locked notes is documented, and a script decrypts them without the app.
- Zero compiler warnings; 38 unit tests and both app checks, including new scenarios for the findings above.

## Remaining

**Security**
- For Touch ID the key lives in the regular keychain and the app itself checks the fingerprint. Storing it in the data-protection keychain with `.biometryCurrentSet` access would be safer; this needs testing on a real Mac with Touch ID.
- In the locked-note format the title and version aren’t bound to the ciphertext (no AAD): encrypted parts can be swapped between notes. This needs format version 2.
- Backups archive the whole library, including the `.pero/cache` index.

**Data**
- No conflict copy: if a file changes on disk while the note has unsaved edits, saving overwrites the change (STO-03).
- Renaming a note updates `[[Title]]` links even when they point to a different note with the same title.
- A failure halfway through moving notes to the trash or restoring them leaves the bookkeeping (`state.json`, the index) stale until the next launch.
- Moving notes to another library leaves copies in both if it fails halfway; locked notes are skipped without a message.
- After switching the library folder, separate note windows and Quick Note keep working with the old one. Locked notes in folders from disk open with the main library’s password and can’t be opened after “Start Empty” (they open again after switching back to the old folder).
- Rows in Recently Deleted are still told apart by their original path; when two match, the first one opens.

**Editor and extensions**
- Large notes: the word count recounts the whole text after every edit, tables are rebuilt on every cursor move, and a note open in two windows sends its whole text on every keystroke.
- Pasted and dropped files travel from the page in full as base64; finding a duplicate attachment reads files on the main thread.
- Quick Look has no size limit; UTF-16 and Latin-1 files are read as Windows-1251.
- Unused code: `rekey` and some editor commands Swift never calls. Tag suggestions after `#` also appear inside code.

**Project**
- Translations: the keys are the Russian strings; English lives in the `en.lproj/Localizable.strings` of the app and the extensions, and the editor’s in `web/src/i18n.js`. A new string without a translation shows up in Russian for English users; to check, build with `SWIFT_EMIT_LOC_STRINGS=YES` and compare the keys.
- CI runs only `swift test` (`.github/workflows/tests.yml`); the full build with extensions and the app checks need signing and a window, and run locally.
- No address for reporting vulnerabilities (`SECURITY.md`).
