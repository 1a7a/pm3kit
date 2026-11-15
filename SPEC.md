# pm3kit specification

## Summary

pm3kit is a small native macOS app that puts a graphical front end on the
Proxmark3 Iceman command line. It is a **wrapper over the existing `pm3` CLI**,
built for personal, day-to-day use: scan a card, save it to a library, clone it
to a blank, verify the copy, without retyping `pm3` commands each time.

It adds no new RFID capability of its own. Everything it does, `pm3` already
does from a terminal. The app's value is a card library, sensible defaults, and
turning a scan-clone-verify session into a few clicks.

```
pm3kit (SwiftUI)  --runs-->  pm3 CLI  --USB-->  Proxmark3
```

The app launches the `pm3` binary as a subprocess and parses its text output.
Nothing in the app touches USB directly; the CLI owns the hardware link. macOS
only, by design: there is no third-party USB-serial access on iOS.

## Scope

**In scope:** a personal tool for one user and their own cards. Scan, library,
clone, verify, backup. 125 kHz (EM410x, HID Prox) and 13.56 MHz (MIFARE
Classic). Dual-frequency cards as two independent tracks under one entry.

**Out of scope:** anything multi-user, any server or sync, any card type the
CLI cannot already read or write, and any attempt to bypass encryption.
Encrypted cards (DESFire, MIFARE Plus SL3, SEOS, iCLASS SE) are detected and
flagged as not cloneable, because no tool can clone them; re-enrol at the access
system instead.

## Architecture

| Path | Role |
|---|---|
| `pm3kit/PM3KitApp.swift` | App entry point, shared `CardStore`, Settings scene |
| `pm3kit/ContentView.swift` | Window: sidebar list, detail pane, buttons, log, sheets |
| `pm3kit/Library.swift` | `CardStore`: the saved-card library, autosaves to disk |
| `pm3kit/PM3.swift` | `pm3` runner, output parsing, scan/clone/verify, magic detection, import |
| `pm3kit/PM3SettingsView.swift` | Settings: `pm3` binary path, library backup and restore |
| `pm3kit/AddLFCardSheet.swift` | `LFCardFamily` and the EM410x / HID Prox manual-entry sheet |
| `pm3kit/CardSortOrder.swift` | Sidebar ordering, including manual drag order |
| `pm3kit/LibraryArchive.swift` | Library backup and restore as one portable JSON file |
| `Tests/` | Unit tests, each named after the file under test |
| `project.yml` | XcodeGen spec; the source of truth for the Xcode project |
| `scripts/build-app.sh` | Test, build Release, install to `~/Applications` |

Runtime data lives in `~/Library/Application Support/pm3kit/`: `library.json`
and a `dumps/` folder for MIFARE dump and key files.

## The pm3 interface

The app issues exactly these commands. They are the contract with the CLI.

- **Scan:** `hf search`; if MIFARE Classic, `hf mf autopwn` (cwd = dumps dir);
  then `lf search`.
- **Clone MIFARE:** `hf mf info` to fingerprint the blank, then `hf mf cload -f
  <dump>` for Gen1a or `hf mf restore --1k -f <dump>` for Gen2/CUID. A
  non-magic, Gen3 or Gen4 blank aborts with a message rather than writing.
- **Clone EM410x:** `lf em 410x clone --id <id>`, to a T5577.
- **Clone HID Prox:** `lf hid clone -r <raw>`, to a T5577.
- **Verify:** `lf em 410x reader` (EM410x), `lf hid reader` (HID Prox), or
  `hf 14a reader` (MIFARE, UID compare only).

Every call has a deadline: 90s for searches and readers, 900s for `autopwn` and
clone writes. This is required, not optional. With no Proxmark3 attached, `pm3`
prints `Waiting for Proxmark3 to appear...` and never exits, so an un-timed call
hangs the app. `pm3` is itself a shell wrapper around the `proxmark3` client
that holds the USB port, so on timeout the whole process tree is signalled.

## Feature status

| Feature | State |
|---|---|
| Scan: auto-detect HF + LF, save both as tracks | Built; parsers validated against captured output, not live hardware |
| MIFARE Classic read via `hf mf autopwn` | Built, not run on hardware |
| EM410x read via `lf search` | Built; parser validated against real captures |
| HID Prox read via `lf search`, clone via `lf hid clone -r` | Built; parser validated against real captures |
| Clone MIFARE: detect magic gen, pick `cload`/`restore` | Built; Gen1a not run on hardware, Gen2/restore never exercised |
| Clone EM410x / HID Prox to T5577 | Built, not run on hardware |
| Verify (EM410x full, HID Prox full, MIFARE UID-only) | Built; MIFARE block-level diff is open item 1 |
| Encrypted card detection, flagged not cloneable | Built, not run on hardware |
| Card library: list, rename, notes, drag-reorder, sort, persist | Built, working |
| Manual import: EM410x serial, HID Prox raw, MIFARE dump set | Built; import verified against real dump sets |
| Dual-frequency: scan both, or build from parts via add-track | Built |
| Library backup / restore to one portable JSON file | Built, unit-tested |

## Open work

1. **MIFARE block-level verify.** Verify currently compares the UID only. Add a
   real diff: re-read the clone and compare it against the stored dump,
   block by block. This is the largest piece of unwritten functionality and
   does not need hardware to write, only to exercise.

2. **End-to-end run on hardware.** Clone and verify have never written to a
   blank through the app. The command strings match known-good manual runs and
   the parsers are validated against captured output, but a live
   scan-clone-verify pass against a real Proxmark3 is the one gap no amount of
   offline testing closes.

3. **Gen2/CUID `restore` path, written but never exercised.** `restore`
   authenticates with the keys recovered from the source card, while a fresh
   CUID blank ships with `FFFFFFFFFFFF`. If the first authentication fails,
   change the Gen2 path to authenticate with default keys first (supply an
   all-`FF` keyfile, or write block 0 with the default key before `restore`). A
   card whose sectors all use default keys cannot surface this, because then the
   recovered keys are the defaults; test with a card that has real keys.

## Build and test

The Xcode project is generated from `project.yml`. Do not edit it in Xcode's UI;
a regenerate discards those changes. After adding or renaming a source file, run
`xcodegen generate`.

```sh
xcodebuild test -project pm3kit.xcodeproj -scheme pm3kit
scripts/build-app.sh            # test, build Release, install to ~/Applications
```

There is no linter, so a clean build plus the test suite is the whole automated
gate. Tests generate their own fixtures and need no hardware or real card data.

`ENABLE_APP_SANDBOX: NO` is load-bearing: a sandboxed build cannot launch `pm3`
or reach USB and fails only at runtime. `scripts/build-app.sh` refuses to
install a sandboxed bundle; keep that check.

The `pm3` path defaults to `/opt/homebrew/bin/pm3`. If `which pm3` differs,
change it in Settings (Cmd-, or the sidebar gear). The sidebar shows a green
check when an executable exists at the stored path.

## Hardware notes

- EM410x and HID Prox clone to a **T5577**.
- MIFARE Classic clones to a **magic** card. Gen1a and Gen2/CUID are both
  supported; the clone fingerprints the blank with `hf mf info` and picks the
  command. Gen1a is detectable by readers that probe the magic backdoor;
  Gen2/CUID is the escalation when a reader rejects a Gen1 clone. Gen3 and Gen4
  are not supported.
- Dual-frequency blanks are almost all Gen1a on the HF side. The app clones per
  track, so a dual card can also be reproduced as two separate blanks
  (T5577 + magic MIFARE) rather than one dual blank.

## Credentials and privacy

Card identifiers, dumps, key files and session logs are access credentials and
must never enter the repository. See [AGENTS.md](AGENTS.md) for the rule and how
tests avoid real data.
