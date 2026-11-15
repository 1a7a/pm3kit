# pm3-kit (native macOS app)

A SwiftUI Mac app that wraps the Proxmark3 Iceman CLI. Scan a card into a saved
library, clone it to a blank, verify the copy. No server, no Python, no second
device. The app runs the `pm3` binary as a subprocess and parses its output.

```
pm3-kit (SwiftUI)  --runs-->  pm3 CLI  --USB-->  Proxmark3
```

## Files

| File | Role |
|---|---|
| `PM3KitApp.swift` | App entry point |
| `ContentView.swift` | Window: card list, detail, buttons, log |
| `Library.swift` | Saved-card store (autosaves to disk) |
| `PM3.swift` | pm3 CLI runner, output parsing, scan/clone/verify |
| `PM3SettingsView.swift` | Settings scene: pm3 binary path |
| `LibraryArchive.swift` | Library export and restore as one portable JSON archive |

## Build

The Xcode project is generated from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and is **not** checked in.
Generate it once after cloning:

```sh
brew install xcodegen     # once
xcodegen generate
open pm3kit.xcodeproj      # then Build and Run (Cmd-R)
```

Or from the terminal:

```sh
xcodebuild -project pm3kit.xcodeproj -scheme pm3kit -configuration Debug build
xcodebuild test -project pm3kit.xcodeproj -scheme pm3kit
```

## Install it as an app

To get a real app you can launch from Spotlight rather than from Xcode:

```sh
scripts/build-app.sh                 # installs to ~/Applications
scripts/build-app.sh /Applications   # or anywhere else
```

The script regenerates the project, runs the tests, builds Release, refuses to
install if the App Sandbox entitlement ever comes back, and copies the bundle
into place. The result is a universal binary, ad-hoc signed, so it needs no
Apple developer account and no Gatekeeper exception when built locally.

After adding, removing, or renaming a file under `pm3kit/`, regenerate:

```sh
brew install xcodegen      # once
xcodegen generate          # reads project.yml at the repo root
```

Edit `project.yml`, never the project settings in Xcode's UI: a regenerate
overwrites anything set there. The spec already does the two things that matter:
`ENABLE_APP_SANDBOX: NO` (a sandboxed app cannot launch `pm3` or reach USB) and
ad-hoc code signing, so no Apple developer account is needed.

## Configure

The app runs whatever `pm3` binary the settings name. Open **Settings** with
Cmd-, or the gear in the sidebar footer. The default is `/opt/homebrew/bin/pm3`
(Apple Silicon Homebrew); Intel is usually `/usr/local/bin/pm3`. Compare against
`which pm3`, or use **Choose…** to pick the file.

The sidebar footer shows a green check when an executable exists at the stored
path and an orange warning when it does not. That check only proves a file is
there and runnable, so confirm the CLI itself works too:

```sh
pm3 -c "hw version"
```

## Using it

- **Scan new card** reads both bands. Each band it finds becomes a track. A
  dual-frequency card gets two tracks (LF + HF) under one saved entry.
- The **Sort** menu in the sidebar orders the list by name, date added, or
  card type. Leave it on **Manual order** to arrange cards yourself by
  dragging; the other orders are derived, so dragging is disabled in them.
- Every scan is saved to the library with its type, ID/UID, dump, and date.
  Rename it and add notes (which door, whose card). It persists across launches.
- Each track has its own **Clone** and **Verify**. For a dual-freq copy you
  write each track to its matching blank. With separate blanks, clone LF, swap
  the blank, clone HF. With a true dual-freq blank, clone both onto the one card.

### Importing cards you already have

Use the **Add existing** menu in the sidebar:

- **Add EM410x by ID.** Type the 10-hex serial and a name. An EM410x card is
  nothing but that serial, so this is a full card: no scan needed, clone it
  straight to a T5577.
- **Add HID Prox by raw.** Type or paste the raw value that `lf search` prints,
  such as `000000000000002004d2162e`. That raw value is the card. The 26-bit
  and 27-bit format guesses pm3 lists next to it (H10301, Indala, Tecom) are
  candidate decodings of the same signal, not separate identities. HID Prox
  also clones to a T5577.
- **Import MIFARE dump files.** `hf mf autopwn` writes a set, not one file
  (`-dump.bin`, `-dump.json`, `-dump.eml`, `-key.bin`). The picker takes
  multiple files: select the whole set. The app copies them together and uses
  the dump as the card, keeping the key file beside it. A UID number alone is
  not enough for MIFARE; the dump is. Gen1a clone works from the dump alone.
  Gen2 `restore` also needs the `-key.bin`, which is why you import the set.

### Backup and restore

In **Settings** (Cmd-, or the gear in the sidebar footer), under **Library
backup**:

- **Backup…** writes the whole library to one `.json` file. The name defaults
  to `pm3kit-backup-<YYYY-MM-DD-HHMM>.json` and you can change it and pick any
  folder.
- **Restore…** reads a backup file back in.

The backup embeds every dump and key file, so it restores on any Mac. That
matters because `library.json` on its own does not travel: it stores absolute
dump paths that include your home folder, so a straight copy of
`~/Library/Application Support/pm3kit/` breaks MIFARE cards on a machine with a
different user name. A backup stores bare filenames and no home directory
appears in the file.

Restore merges rather than replaces. Cards already in the library are skipped by
id, so restoring the same file twice changes nothing. If a dump filename is
taken by a file with different contents, the whole set is renamed together so
the dump and its `-key.bin` keep the shared stem that Gen2 `restore` needs.

**Building a dual-frequency card from imports.** The sidebar menu adds a new
card. To make one card hold both bands, open a card first: its detail pane shows
"Add EM410x track" and "Import MIFARE track" for whichever band it is missing.
Add the missing band there and the card becomes dual-frequency. A scanned
dual-freq card already arrives with both tracks.

Library and dumps live in `~/Library/Application Support/pm3kit/`.

## Blanks

- **T5577** for LF (EM410x).
- **Magic MIFARE 1K** for MIFARE Classic. Clone fingerprints the blank first
  with `hf mf info` and picks the command: `hf mf cload` for Gen1a,
  `hf mf restore` for Gen2/CUID. A plain (non-magic) card, Gen3, or Gen4 blank
  aborts the clone with a message instead of writing a broken card.
- **Dual-frequency blank** (T5577 + magic MIFARE in one body) to copy a
  dual-freq card onto a single card.

## Encrypted cards

A track marked **cannot clone** uses a live crypto handshake (DESFire, MIFARE
Plus SL3, SEOS, iCLASS SE). The keys never leave the chip, so no tool copies it.
Enroll a new card at the access system instead. MIFARE Classic is not in this
group and clones fine.

## Status

The pm3 command strings are correct. Output parsing (`PM3.parseHF`,
`PM3.parseLF`, `PM3.grabUID`) matches the Iceman client's current format but has
not been tested against live hardware. Run Scan on real cards and tune the
regexes from the raw log in the window.
