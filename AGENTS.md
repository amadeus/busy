# Working on Busy

Busy is a macOS 14+ Swift package with an AppKit menu bar app, a CLI, and an
optional privileged helper. Keep the app small and preserve its quit-when-done
behavior.

## Project layout

- `Sources/BusyApp`: menu bar UI, battery monitoring, idle-sleep assertion.
- `Sources/BusyCLI`: command parsing, app launch, and session control.
- `Sources/BusyCore`: shared protocol, sockets, settings, session and helper logic.
- `Sources/BusyHelper`: privileged sleep control and recovery.
- `Resources/Icons`: canonical SVGs and generated app/menu bar assets.
- `Resources/Installer`: package scripts, component choices, and installer tests.
- `scripts`: build, packaging, icon generation, and CLI checks.

## Behavior to preserve

- A fresh launch starts unlimited unless a duration is explicitly supplied.
  Plain `busy` preserves a running countdown; an explicit duration resets it.
- Only the battery cutoff persists. Its default is 20%, and it applies only
  while on battery. Battery protection takes precedence over duration.
- At the cutoff, on timeout, or on stop, quit and release sleep prevention.
  Do not force the Mac to sleep. Allow the display to turn off.
- The menu bar and CLI control the same app session.
- Preserve helper heartbeat expiry, independent battery checks, durable recovery,
  and existing authorized-user configuration across upgrades. Never discard a
  recovery journal before restoring the saved power setting.
- The package stops the installed Busy app before replacement. Target its exact
  executable path, preserve unrelated processes, and restore the old helper's
  sleep settings before replacing it.
- Use a template image for the menu bar icon so macOS controls its tint.

## Validation

Run checks relevant to the change:

```sh
swift test
./scripts/build.sh
python3 scripts/test-cli.py build/busy
python3 Resources/Installer/test-scripts.py
git diff --check
```

`python3 scripts/test-cli.py build/busy --live` exercises app lifecycle behavior.
It skips when the helper is installed. Do not remove a user's helper just to run
the tests. Report skipped live checks and distinguish automated checks from
physical lid, battery, and installer testing.

For package changes, run `./scripts/package.sh`, inspect the extracted payload,
and verify the extracted app with `codesign --verify --deep --strict`. Confirm
the app version, architectures, CLI symlink, resources, and installer scripts.
Do not install a package or alter system power settings merely to inspect it.

## Assets and releases

- Run `swift scripts/render-icons.swift` after editing SVGs. It uses WebKit and
  needs access to macOS GUI services. ImageMagick's SVG renderer loses the
  filters in these icons; do not use it to regenerate them.
- Inspect rendered icons and transparency. Keep app icon sizes and both menu
  bar scales in sync with their SVG sources.
- Update both version fields in `Resources/Info.plist` for a release.
- `build/` and `.build/` are scratch/output directories and stay untracked.
  The versioned `.pkg` at the repository root is an intentional release artifact.
  When updating that artifact, copy the verified package from `build/`, confirm
  byte-for-byte equality, and update the README download link.
- Keep plan files, including `PLAN.md`, out of commits. Preserve unrelated work.

## Rex

Never run `rex session rename` unless the user explicitly asks. Do not start
`caffeinate` to keep this workspace awake; Busy is the app being used for that.
