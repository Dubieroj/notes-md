<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

# Notes.md

[![Tests](https://github.com/Dubieroj/notes-md/actions/workflows/tests.yml/badge.svg)](https://github.com/Dubieroj/notes-md/actions/workflows/tests.yml)

**English** · [Русский](README.ru.md)

**Notes.md** is a Mac notes app that works like Apple Notes, except every note is a plain Markdown file. Folders, smart folders, tags, pinned notes, Recently Deleted, Quick Note, locked notes with a password and Touch ID, widgets and Spotlight search — while your data stays as simple `.md` files you can open in any editor and keep in git. It works offline, with no accounts and no network.

**Open source.** The code is dedicated to the public domain ([Unlicense](LICENSE)): take it, change it, embed it, sell it — no conditions, no attribution required.

The interface is in English and Russian, following the system language. Further reading: the format of locked notes in [docs/locked-format.md](docs/locked-format.md), the pre-release audit and known issues in [docs/AUDIT.md](docs/AUDIT.md), and the original design spec (in Russian) in [docs/SPEC.md](docs/SPEC.md).

## Building

You need macOS 15 or later and Xcode (tested with Xcode 26.3, Swift 6.2).

```bash
./run.sh
```

The script builds `build/Notes MD.app` and launches it.

- **The full app** with its extensions (widgets, Share, Quick Look for `.md`, Shortcuts and Siri actions) is built when `xcodegen` (`brew install xcodegen`) and an Apple Development certificate are available — a free one from Xcode ▸ Settings ▸ Accounts will do. The script takes the development team from the certificate; to use another one: `PERO_TEAM=XXXXXXXXXX ./run.sh`. The bundle identifier `local.pero.markdown` belongs to the author's team, so with your own team set your own: `PERO_BUNDLE_ID=com.example.notes ./run.sh`.
- **Without xcodegen or a certificate** (or with `PERO_SPM=1`) only the app itself is built, with SwiftPM, without extensions.
- **Node.js** is only needed when you change `web/`: the built editor page is already in `Resources/web`, and `run.sh` rebuilds it when `npm` is available.
- **Tests**: `swift test` for the core, plus the two app checks described under [How it’s built](#how-its-built).

Notes live in `~/Library/Application Support/Pero/Library`. You can pick another folder in Settings: the app offers to move your notes there, start empty, or open the folder as an existing library, and switches right away without a restart.

## Features

**Like Apple Notes**

- **Three columns**: folders, the note list, the note. A note’s title is its first line, and the file is named after it.
- **Folders and subfolders** (⇧⌘N), drag and drop of notes and folders, inline renaming, Show in Finder. A folder in the app is a folder on disk.
- **List and gallery** (⌘1 / ⌘2), a Pinned section and date groups (Today, Yesterday, Previous 7 Days…), sorting by date edited, date created or title — globally or per folder.
- **Pinning**, **duplicating** (⌘D), a note in **its own window** (double-click), two-finger swipes in the list: right to pin, left to delete or share.
- **Recently Deleted**: notes are kept for 30 days and can be restored or deleted permanently; ⌘Z undoes a deletion.
- **Tags** written as `#tag` right in the text, a tag browser in the sidebar, renaming and deleting a tag across all notes at once.
- **Smart folders** with the Notes filters: tags, dates created and edited, checklists, attachments, folders, Quick Notes, pinned, locked; match all filters or any. Convert to Smart Folder.
- **Search** across all notes (⌥⌘F), matching word beginnings. Find and replace within a note (⌘F).
- **Formatting with the Notes shortcuts**: Title ⇧⌘T, Heading ⇧⌘H, Subheading ⇧⌘J, Body ⇧⌘B, Monostyled ⇧⌘M, lists ⇧⌘7/8/9, block quote ⌘', checklist ⇧⌘L, mark as checked ⇧⌘U, table ⌥⌘T, divider ⌘L, ⌘B/⌘I/⌘U/⇧⌘X, highlight ⇧⌘E, link ⌘K, indent ⌘] / ⌘[ and Tab, move items ⌃⌘↑/↓. Everything is written as plain Markdown.
- **Checklists** with round checkboxes, Check All, Move Checked to Bottom, and automatic sorting of checked items (in Settings).
- **Tables** drawn as a grid, with the Notes keys: Tab/⇧Tab between cells, ↩ for the next row, ⌥⌘arrows for a new row or column.
- **Links between notes**: `>>` or `[[` shows a list of notes; clicking a link opens the note, ⌥⌘[ / ⌥⌘] go back and forward. Link to a section: `[[Note#Section]]`. Renaming a note updates the links to it.
- **Attachments**: pictures, PDFs and any files go into the `Attachments` folder by drag and drop, paste or Attach File (⇧⌘A); pictures have a resize handle. Insert from iPhone or iPad (photo, scan or sketch via Continuity Camera). All attachments of the library: ⌘3.
- **Collapsible sections** under headings (the arrow next to a heading).
- **Quick Note** with ⌃⌥⌘N from any app: a small window above everything, on every desktop.
- **Locked notes** with a password and Touch ID: the text is encrypted (AES-256-GCM), the title stays visible, as in Notes. Close All Locked Notes, and automatic locking after inactivity, sleep and screen lock.
- **Import**: Markdown and text (with pictures and folder structure), RTF, RTFD, HTML, Evernote (ENEX), and Import from Apple Notes via AppleScript.
- **Export** (PDF, Markdown with attachments, single-file HTML, plain text) for one note, several, or a whole folder; **printing** (⌘P); Share and AirDrop.
- **Copy and paste**: ⌘C puts both Markdown and formatted text on the clipboard; pasting from a browser, Pages or Google Docs becomes Markdown; Copy as Markdown; Paste and Match Style (⌥⇧⌘V).
- **Interface language**: English or Russian, following the system; English for all other languages. Folders the app creates itself (Quick Notes, Imported Notes) get names in the interface language in a new library, and keep their names in an existing one.
- **Text size** (⇧⌘. / ⇧⌘, / ⇧⌘0), light and dark appearance following the system, Notes-style Settings (⌘,).
- **macOS integration**: notes in Spotlight, Note, Folder and Pinned widgets, Share ▸ Notes.md from any app, Shortcuts and Siri actions (“New note in Notes.md”), Quick Look for any `.md` in Finder.

**What Markdown adds**

- **Live formatting**: markup is hidden and shows only for the element under the cursor. Source mode: ⌘/.
- **No damage to your Markdown**: untouched parts of a file stay byte for byte the same (UTF-8 or Windows-1251, BOM, Windows line endings).
- **Files instead of a database**: open the library in Finder, put it in git, edit it with other apps — changes are picked up live. The SQLite database is only a search index and can be deleted.
- **Suggestions** for note names after `[[` / `>>`, tags after `#`, and languages after ```` ``` ````; syntax highlighting for about 100 languages.
- **Folders from disk**: File ▸ Connect Folder from Disk… (or the button at the bottom of the sidebar) shows any folder of `.md` files under Folders on Disk. Notes are edited right in those files and nothing is copied; the app keeps the index and trash for such a folder on its side and never renames the files in it. Notes can be moved between a folder from disk and the library, pictures included. Disconnect Folder leaves the files alone.
- **Pictures and files at any path**: `![](/Users/…/scan.png)`, `![](~/Pictures/…)` and `file://` links are shown in the note and open on click.
- **Tag colors**, a word count and reading time (in Settings), and scheduled backups to iCloud Drive.

**Any Markdown file from Finder** (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mkdn`, `.mdwn`, `.mdtxt`, `.mdtext`, read-only ones included) opens in its own editor window with a folder tree and an outline; notes from the library and from connected folders open in the main window. If another app keeps appending to the file (a speech-to-text app, say), the text updates in place. To have Finder open all such files here: Settings ▸ Markdown files ▸ Open in Notes.md.

In Finder, Launchpad and the Dock the app is called “Notes MD”: macOS would show a name ending in “.md” with “.app” appended, so it can’t be mistaken for a document. The menu bar and the About window say “Notes.md”.

## Open source

- License: [Unlicense](LICENSE) — the code is in the public domain. Do anything with it: fork, rename, sell, embed in closed-source apps; no permission or attribution needed.
- The editor’s third-party libraries (CodeMirror, Lezer, markdown-it and their dependencies) keep their own licenses (MIT, BSD-2-Clause, PSF-2.0). `web/build.mjs` collects their texts on every build into [Resources/web/third-party-licenses.txt](Resources/web/third-party-licenses.txt), which also ships inside the app.
- The Markdown mark in the icon was drawn by Dustin Curtis and dedicated to the public domain (CC0). The icon is drawn by `tools/make-icon.swift`.
- The project’s internal name is Pero: it is used by the build targets (`Pero`, `PeroKit`), the identifier `local.pero.markdown`, the `pero://` scheme and the `.pero/` data folder. They were kept so that settings, passwords and libraries from earlier versions keep working.
- Interface strings are written in Russian in the code and serve as translation keys; English lives in `Resources/en.lproj/Localizable.strings` (and the extensions’ own `en.lproj`), the editor’s in `web/src/i18n.js`.
- Contributions are welcome. Before sending one, run `swift test`, `tools/check-library.sh` and `tools/check.sh`.

## How it’s built

- `Sources/PeroKit/` — the core, no UI: the file library, note parsing (title, tags, links, tasks), the SQLite index with full-text search, the trash, smart folders, encryption, rewriting of paths and links. Covered by tests (`swift test`).
- `Sources/Pero/` — the AppKit app: the main window, lists, sidebar, note sessions with autosave, menus, import and export, locking, Quick Note, Spotlight, Shortcuts actions, the window for external `.md` files.
- `web/src/` — the editor, [CodeMirror 6](https://codemirror.net) in a `WKWebView`: live formatting (`livepreview.js`), Notes commands (`notes.js`), syntax for `==highlights==`, `[[links]]` and `#tags` (`syntax.js`), suggestions, clipboard, export through [markdown-it](https://github.com/markdown-it/markdown-it). The page loads only from `pero://`; pictures from the internet are not loaded.
- `Extensions/` — widgets, Share, Quick Look. The Xcode project is generated from `project.yml`.
- `tools/check-library.sh` — an end-to-end check of the notes: it starts a separate instance on a temporary library and goes through scenarios like a user would (creating, formatting, `>>`, pinning, search, moving, trash, external edits, export, import, smart folders, locking, folders from disk, pictures at absolute paths, switching the library folder), checking the files on disk.
- `tools/check.sh` — a check of the window for external `.md` files, including “open, save, same bytes” on your own files: `tools/check.sh ~/path/to/*.md`.

Both checks build their own copy of the app with a test control channel (`PERO_TEST_HOOKS=1 ./run.sh`, into `build/test/`; the regular build doesn’t have it), work in temporary folders, and never touch your real notes or the installed app.

## Limitations

- Tables are edited as source: clicking a cell shows that table row with the cursor in it.
- Highlighting comes in one color (Notes has five); fonts and text colors don’t carry over — Markdown has none.
- Only notes without attachments can be locked: only the text is encrypted. Locked notes in folders from disk open with the library’s password.
- No Math Notes, audio recording with transcription or trackpad drawing yet; Handoff isn’t supported (it would need an iOS version).
- Formulas, footnotes and diagrams stay as text.
