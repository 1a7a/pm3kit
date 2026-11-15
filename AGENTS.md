# AGENTS.md

Conventions for this repository, for humans and coding agents alike.

## The hard rule: no real credentials, ever

This project reads and writes **access-control credentials**. A card UID, an
EM410x serial, an HID Prox raw value or a MIFARE dump is the functional
equivalent of a key to a door. Treat all of it as secret.

Never commit, and never paste into an issue, a pull request, a commit message
or a chat transcript:

- Card identifiers of any kind: MIFARE UIDs, EM410x serials, HID Prox raw
  values, Indala or Tecom decodings.
- Card dumps or key files: `*-dump.bin`, `*-dump.json`, `*-dump.eml`,
  `*-key.bin`, or anything derived from them.
- Proxmark3 session logs. `~/.proxmark3/logs/` records every scan in full.
- Personal data: real names, email addresses, home-directory paths
  (`/Users/<name>/...`), private repository URLs, building or tenant names.

Use invented values in tests, documentation and UI copy. The existing examples
(`1A2B3C4D5E`, `DEADBEEF`, `000000000000002004d2162e`) are made up; keep new
ones equally fictional and obviously so.

`.gitignore` blocks the common dump and log extensions, but it is a safety net,
not a substitute for checking `git diff` before you commit. If credentials do
land in a commit, treat the credential as compromised: rotate or re-enrol the
card. Rewriting the history is not enough, because pushed objects stay
reachable by SHA until the host garbage-collects them.

### Testing without real cards

Tests must generate their own fixtures. `Tests/PM3ImportTests.swift` writes
autopwn-shaped files into a temporary folder; follow that pattern. No test may
read from a developer's home directory or require particular hardware.

When you need to validate a parser against genuine output, do it locally
against your own logs and commit only the conclusion, never the capture.

## Layout

| Path | Role |
|---|---|
| `pm3kit/` | Application sources |
| `Tests/` | Unit tests, named after the file under test |
| `project.yml` | XcodeGen spec; the source of truth for the Xcode project |
| `scripts/build-app.sh` | Test, build Release, install to `~/Applications` |

`pm3kit.xcodeproj` is generated. Edit `project.yml` and run `xcodegen generate`;
changes made in Xcode's UI are discarded on the next regenerate.

## Build and test

```sh
xcodebuild test -project pm3kit.xcodeproj -scheme pm3kit
scripts/build-app.sh
```

There is no linter. A clean build plus the test suite is the whole automated
gate, so keep the suite meaningful.

**`ENABLE_APP_SANDBOX: NO` is load-bearing.** A sandboxed build cannot launch
`pm3` or reach USB, and fails only at runtime. `scripts/build-app.sh` refuses to
install a sandboxed bundle; do not remove that check.

## Code style

Names are how both people and agents find code, so prefer specific ones:
`hidProxRawID`, not `parse`. Keep one term per concept throughout.

Do not add comments by default; let names and types carry the meaning. Reserve
comments for things the code cannot say: an external constraint, a workaround
for upstream behaviour, or a non-obvious invariant. Several comments in
`PM3.swift` exist because the `pm3` output format forces a specific ordering;
leave those in place.

## Working with the pm3 CLI

Every call goes through `PM3.runCLI`, which enforces a deadline. Without one the
app hangs forever: with no Proxmark3 attached, `pm3` prints
`Waiting for Proxmark3 to appear...` and never exits. `pm3` is a shell wrapper
around the `proxmark3` client that holds the USB port, so the timeout path
signals the whole process tree. Do not bypass `runCLI`.

## Commits

Conventional Commits: `type(scope): summary`. Say *why* in the body, not just
what. Work happens on `main`; there is no PR flow.
