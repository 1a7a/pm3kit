# pm3-kit

A native macOS app that wraps the Proxmark3 Iceman CLI with a simple screen:
scan a card into a saved library, clone it to a blank, verify the copy.

Runs entirely on the Mac that has the Proxmark3 attached. No server, no second
device. The app launches the `pm3` CLI as a subprocess; the CLI owns the USB
link to the hardware.

```
pm3-kit (SwiftUI)  --runs-->  pm3 CLI  --USB-->  Proxmark3
```

Supports 125 kHz (EM410x and HID Prox, both to T5577), 13.56 MHz (MIFARE
Classic to Gen1a or Gen2/CUID magic), and dual-frequency cards (two tracks,
cloned and verified independently).
Encrypted cards (DESFire, SEOS, iCLASS SE) are detected and flagged as not
cloneable.

Build: open `pm3kit.xcodeproj` and run. The project is generated from
`project.yml` by XcodeGen; run `xcodegen generate` after adding or renaming a
source file.

The card library backs up to a single portable `.json` file and restores from
it, so backups survive a move to another Mac.

See [`pm3kit/README.md`](pm3kit/README.md) for build and usage.
See [`SPEC.md`](SPEC.md) for the specification, feature status, and open work.

## Contributing

Read [AGENTS.md](AGENTS.md) before changing anything. The short version:

**Never commit real card data.** A UID, an EM410x serial, an HID Prox raw value
or a MIFARE dump is a working key to a door. Card identifiers, dumps, key files,
Proxmark3 session logs from `~/.proxmark3/logs/`, home-directory paths and real
names stay out of the repository, out of commit messages and out of issues. Use
invented values; the ones already in the tests and documentation are fictional.

Tests generate their own fixtures and need no hardware:

```sh
xcodebuild test -project pm3kit.xcodeproj -scheme pm3kit
```

## Legal

This tool automates a CLI you must already be licensed to use, against cards you
own or are authorised to duplicate. Cloning an access credential you do not own
is likely illegal where you live. That is your responsibility, not the project's.
