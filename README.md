# v25 Mod Builder

> **macOS:** this app isn't notarized, so Gatekeeper will block it (and may
> move it straight to Trash) after downloading. Recover it from Trash if
> needed, then run:
> ```bash
> xattr -cr "/Applications/v25 Mod Builder.app"
> ```
> before opening it. See [Packaging](#packaging-optional) below for why.

A small cross-platform (Windows/macOS/Linux) Electron GUI for building and
exporting MoSimulator addressable mod groups, without hand-running the
`Tools/build-mods-all-platforms.ps1` script in the MoSim-Reefscape-Public repo.

It drives the existing `Editor.AddressablesModExporter.BuildFromCommandLine`
method already in that Unity project — it doesn't change anything in the
Unity project itself. That C# method is what actually sets the per-group
bundle-naming prefix, builds addressables, copies the platform catalog files
+ robot DLLs into `Mods/<GroupName>/`, and zips the result. This app just
launches Unity headless with the right arguments, once per selected platform,
and shows you progress/logs.

## Setup

Requires [Node.js](https://nodejs.org) (LTS).

```bash
npm install
npm start
```

## Using it

1. **Select Unity Project** — pick the root of a Unity project that has
   `Editor.AddressablesModExporter` (i.e. MoSim-Reefscape-Public, or any repo
   with that same Editor script). The app reads the required Unity Editor
   version from `ProjectSettings/ProjectVersion.txt` and lists every
   Addressable group it finds under `Assets/AddressableAssetsData/AssetGroups/`,
   except Unity's own default groups and `LynkMod` (the example/template mod
   bundled in the repo, not something meant to be built and shipped). The
   project is remembered and reopened automatically next launch.
2. **Unity Editor** — the app tries the standard Unity Hub install path for
   the required version on your OS. If it's not found (or you want a
   different install), click **Browse for Unity Editor...** and point it at
   your `Unity.exe` (Windows), `Unity.app` (macOS — pick the `.app` bundle
   itself), or `Unity` binary (Linux). This choice is remembered.
3. **Groups to build** — check the group(s) you want. Each checked group
   gets its own optional **Version** and **Zip name override** fields (same
   as the `-Versions`/`-ZipNames` options in the PowerShell script).
4. **Platforms** — Windows/macOS/Linux, all checked by default. Uncheck any
   you don't need this run.
5. **Build** — launches Unity headless once per selected platform, in order.
   Each platform gets its own full Addressables build (required since bundle
   naming settings are project-wide, not per-group) and is verified by
   checking that the expected `.zip` actually landed in `Mods/`, not just by
   trusting Unity's exit code. If a platform fails, the run stops there —
   fix the issue and re-run.

## Packaging (optional)

```bash
npm run dist
```

Uses `electron-builder` to produce an installer for whatever OS you run it
on (`.msi` on Windows, `.dmg` on macOS, `.AppImage` **and** `.pacman` on
Linux). The `.pacman` package is the one to grab on Arch/CachyOS/Manjaro —
install it with `sudo pacman -U "Mod Builder Installer Linux.pacman"` and it
runs immediately, no `chmod +x` or `libfuse2` needed (that's only required
for the AppImage, which is the portable fallback for non-Arch distros). The
Windows
installer is a full multi-page wizard (install location, Start Menu/desktop
shortcut options) built on real Windows Installer (MSI), not a one-click
NSIS installer — so re-running it over an existing install brings up the
standard repair/uninstall/reinstall maintenance dialog automatically; that's
native MSI behavior keyed off a stable upgrade code (derived from `appId`),
not something configured separately. This repo doesn't set up code signing
or notarization — packaged builds will trigger an "unidentified developer"
warning on macOS and a SmartScreen warning on
Windows unless you sign them yourself.

**On macOS specifically**, recent macOS versions (Sequoia+) don't just warn
on an unsigned, unnotarized app — they block it outright with a
"malware blocked and moved to Trash" dialog. Real Apple notarization (which
stops this) requires a paid Apple Developer Program membership ($99/year);
there's no free way around that check, since it validates against Apple's
own servers. The mac build here is ad-hoc signed (`identity: "-"` in
`package.json`, free, no account needed) purely so the app can launch at all
on Apple Silicon — it does **not** satisfy Gatekeeper's notarization check.
Until/unless notarization gets set up, anyone installing on macOS needs to
manually clear the quarantine flag after downloading:

```bash
# If Gatekeeper already deleted it, re-extract "v25 Mod Builder.app" from
# the .dmg first, then:
xattr -cr "/Applications/v25 Mod Builder.app"
```

Or: after the block, open **System Settings → Privacy & Security** and look
for an "Open Anyway" button near the bottom of the page.

### CI builds (GitHub Actions)

`.github/workflows/build-installers.yml` only triggers on a pushed version
tag matching `v*.*.*` (e.g. `v1.0.0`) — nothing runs on ordinary pushes or
PRs. One job per OS builds on GitHub's own Windows/macOS/Linux runners via
`npm run dist`, uploads each installer as a workflow artifact
(`installer-windows`/`installer-macos`/`installer-linux`), then a final job
downloads all three and creates a **GitHub Release** with them attached.
Same caveat as above: these are unsigned builds.

To cut a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Branding

`logo.png` / `logo.ai` at the repo root are the source logo files.
`build/icon.png` is a copy of `logo.png` used as the app icon everywhere:
the runtime window icon (`main.js`), the renderer favicon, and the
packaged-installer icon (`electron-builder`'s `build.icon` /
`build.win.icon` / `build.mac.icon` / `build.linux.icon` config in
`package.json`; it auto-generates `.icns` for macOS from the PNG at
`npm run dist` time).

Windows is the exception: its taskbar/title-bar icon renders blurry from a
single scaled PNG, so it needs a real multi-resolution `.ico` — that's
`build/icon.ico`, pre-generated and checked into `build/`.

To update the logo: replace `logo.png` (and `logo.ai`), copy it to
`build/icon.png`, then regenerate the Windows icon:

```bash
cp logo.png build/icon.png
npm run icon
```

## Known limitations

- Cross-compiling for a platform (e.g. building the macOS zip from Windows)
  requires that build-target's module to be installed in your local Unity
  Editor install, same as building manually.
- The app doesn't manage Unity Editor installs — it only detects or lets you
  point at one you've already installed via Unity Hub.
- Settings (last project path, manual Unity path override, output folder
  override) persist to `settings.json` in Electron's per-OS user-data
  directory (`app.getPath('userData')` — e.g. `%APPDATA%\v25-mod-builder` on
  Windows, `~/Library/Application Support/v25-mod-builder` on macOS,
  `~/.config/v25-mod-builder` on Linux). That's deliberate: it's writable
  per-user storage, unlike the app's own install directory, so settings still
  work once this ships as an installed app (`npm run dist`) living somewhere
  like `Program Files` rather than run from a dev checkout via `npm start`.
  (This app was previously named "MoSim Mod Builder" / `mosim-modbuilder`;
  `main.js` migrates settings.json from that old location automatically.)
