# v25 Mod Builder — source & build docs

Everything that builds the app lives in this folder. The repo root holds only
[`README.md`](../README.md) (the end-user guide) and `.github/` (GitHub only
reads Actions workflows from `.github/workflows` at the repo root, so that
directory can't move in here).

Layout:

```
app/
  main.js, preload.js, unity-*.js   Electron main process
  renderer/                         Electron UI
  mac/                              Native Swift/SwiftUI macOS app (see mac/CONTEXT.md)
  unity/AddressablesModExporter.cs  Unity Editor script shipped with the app
  build/                            App icons (icon.png/.ico/.icns, icons/ for Linux)
  scripts/generate-icon.mjs         Regenerates build/icon.ico and build/icons/
  packaging/aur/PKGBUILD            AUR package for the Linux AppImage
  logo.png, logo.ai                 Source logo files
```

## What it actually does

A cross-platform (Windows/macOS/Linux) Electron GUI for building and exporting
MoSimulator addressable mod groups, without hand-running the
`Tools/build-mods-all-platforms.ps1` script in the MoSim-Reefscape-Public repo.

It drives `Editor.AddressablesModExporter.BuildFromCommandLine` in that Unity
project. That C# method is what actually sets the per-group bundle-naming
prefix and build/load paths, builds addressables, copies the platform catalog
files + robot DLLs into `Mods/<GroupName>/`, and zips the result. This app
launches Unity headless with the right arguments, once per selected platform,
and shows progress/logs.

**That Editor script ships with the app** (`unity/AddressablesModExporter.cs`)
and is installed into `<project>/Assets/Editor/` automatically the first time
the app needs it, then kept up to date by a version marker in the file. That's
deliberate: the public template project everyone clones
([MoSimulator/MoSimulator-Public](https://github.com/MoSimulator/MoSimulator-Public))
doesn't contain it, so requiring people to add it by hand would mean the app
simply doesn't work on a fresh clone. It's the one file the app writes into a
user's Unity project — don't hand-edit the installed copy, since it gets
overwritten; edit `unity/AddressablesModExporter.cs` here instead.

Both GUIs (Electron and the Swift `mac/` app) exclude the same reserved
Addressable group names: `Built In Data`, `EditorSceneList`,
`Default Local Group`, and the bundled example mods `LynkMod`,
`LynkModOfficial`, `MechTechMod`. Mod detection matches by asset GUID, not by
name, so a group whose name has drifted from its folder name is still
recognised as already registered.

## Running it locally

Requires [Node.js](https://nodejs.org) (LTS). All npm commands run **from this
`app/` folder**, not the repo root:

```bash
cd app
npm install
npm start
```

## Packaging

```bash
npm run dist
```

Uses `electron-builder` to produce an installer for whatever OS you run it on
(`.msi` on Windows, `.dmg` on macOS, `.AppImage` **and** `.pacman` on Linux),
written to `app/dist/`. The `.pacman` package is the one to grab on
Arch/CachyOS/Manjaro — it runs immediately after
`sudo pacman -U "Mod Builder Installer Linux.pacman"`, no `chmod +x` or
`libfuse2` needed (that's only required for the AppImage, the portable
fallback for non-Arch distros).

The Windows installer is a full multi-page wizard (install location, Start
Menu/desktop shortcut options) built on real Windows Installer (MSI), not a
one-click NSIS installer — so re-running it over an existing install brings up
the standard repair/uninstall/reinstall maintenance dialog automatically.
That's native MSI behavior keyed off a stable upgrade code (derived from
`appId`), not something configured separately. `perMachine: false` (per-user
install, no admin required).

This repo doesn't set up code signing or notarization — packaged builds
trigger an "unidentified developer" warning on macOS and a SmartScreen warning
on Windows unless you sign them yourself.

### The macOS situation

Recent macOS versions don't just warn on an unsigned, unnotarized Electron app
— they blocked the Electron `.dmg` outright with a "malware blocked and moved
to Trash" dialog (XProtect, not the milder Gatekeeper prompt; ad-hoc signing
and `xattr -cr` both failed to fix it). Real Apple notarization would fix it
for certain but requires a paid Apple Developer Program membership ($99/year).

That's why `mac/` exists: a from-scratch native Swift/SwiftUI rewrite of the
same workflow, on the hypothesis that removing the Electron/Chromium/Node
fingerprint avoids the false positive. **CI releases the native Swift app for
macOS, not the Electron `.dmg`** — see the `build-macos` job in the workflow.
`npm run dist` still produces a mac `.dmg` locally if you ask for one, but it
isn't what ships. Read [`mac/CONTEXT.md`](mac/CONTEXT.md) before touching that
app.

## CI builds (GitHub Actions)

`.github/workflows/build-installers.yml` (at the **repo root**) only triggers
on a pushed version tag matching `v*.*.*` (e.g. `v1.0.0`) — nothing runs on
ordinary pushes or PRs. Because the app lives in `app/`, every step in that
workflow that touches it sets `working-directory: app` (or `app/mac`), and the
artifact globs are `app/dist/*`; `actions/setup-node` is pointed at
`app/package-lock.json` via `cache-dependency-path`.

Jobs:

- **build-electron** — Windows and Linux runners, `npm run dist`, uploads each
  installer as a workflow artifact (`installer-windows` / `installer-linux`).
  The Linux job also boots the packaged binary headlessly under `xvfb` and
  fails the build if it dies on startup, since a file missing from
  `build.files` in `package.json` only shows up once the app is packaged —
  `npm start` runs from the source tree and can't catch it.
- **build-macos** — macOS runner, `swift build -c release` in `app/mac`,
  wrapped into a minimal ad-hoc-signed `.app` bundle and zipped as
  `installer-macos`.
- **release** — downloads all three and creates a **GitHub Release** with them
  attached.

### The README download table

The download table at the top of the root [`README.md`](../README.md) links to
`/releases/latest/download/<asset>`, a GitHub permalink that always redirects
to the newest release. **It never needs editing when you cut a release.**

The one thing that *does* break it is renaming an artifact — the `artifactName`
entries in `package.json`, or the `ditto` line in the workflow's `build-macos`
job. Those names are baked into the README's URLs, and GitHub replaces spaces
with dots in asset filenames (`Mod Builder Installer Mac.zip` is served as
`Mod.Builder.Installer.Mac.zip`), so the URLs use the dotted form. The
**Check README download links match the release assets** step in the `release`
job compares the two and fails the release if they've drifted, rather than
publishing a table of dead links. If you rename an installer, update the table
in the same commit.

To cut a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Branding

`logo.png` / `logo.ai` here are the source logo files. `build/icon.png` is a
copy of `logo.png` used as the app icon everywhere: the runtime window icon
(`main.js`), the renderer favicon, and the packaged-installer icon
(`electron-builder`'s `build.icon` / `build.win.icon` / `build.mac.icon` /
`build.linux.icon` config in `package.json`; it auto-generates `.icns` for
macOS from the PNG at `npm run dist` time).

Windows is the exception: its taskbar/title-bar icon renders blurry from a
single scaled PNG, so it needs a real multi-resolution `.ico` — that's
`build/icon.ico`, pre-generated and checked in.

To update the logo: replace `logo.png` (and `logo.ai`), copy it to
`build/icon.png`, then regenerate the icons:

```bash
cp logo.png build/icon.png
npm run icon
```

## Known limitations

- Cross-compiling for a platform (e.g. building the macOS zip from Windows)
  requires that build-target's module to be installed in the local Unity
  Editor install, same as building manually.
- The app doesn't manage Unity Editor installs — it only detects or lets you
  point at one already installed via Unity Hub.
- Settings (last project path, manual Unity path override, output folder
  override) persist to `settings.json` in Electron's per-OS user-data
  directory (`app.getPath('userData')` — e.g. `%APPDATA%\v25-mod-builder` on
  Windows, `~/.config/v25-mod-builder` on Linux; the Swift app uses
  `UserDefaults` instead). That's deliberate: it's writable per-user storage,
  unlike the app's own install directory, so settings still work once this
  ships as an installed app living somewhere like `Program Files` rather than
  run from a dev checkout via `npm start`. (This app was previously named
  "MoSim Mod Builder" / `mosim-modbuilder`; `main.js` migrates settings.json
  from that old location automatically.)
