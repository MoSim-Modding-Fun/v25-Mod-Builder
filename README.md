# v25 Mod Builder

A desktop app for building and exporting MoSimulator addressable mod groups.
Point it at your Unity project, tick the mods and platforms you want, and it
drives Unity headlessly to produce the finished `.zip` for each platform —
no command line, no hand-run build scripts.

Available for **Windows**, **macOS**, and **Linux**.

## Before you start

You need two things installed already:

- **A MoSimulator Unity project** — a clone of the public template
  ([MoSimulator/MoSimulator-Public](https://github.com/MoSimulator/MoSimulator-Public))
  or of MoSim-Reefscape-Public.
- **The Unity Editor version that project requires**, installed through
  [Unity Hub](https://unity.com/download). The app reads the required version
  from your project and looks for a matching install — it won't install Unity
  for you.

  If you plan to build for a platform you're not on (for example, the macOS
  zip from Windows), install that **build support module** for your Unity
  Editor in Unity Hub first.

You do **not** need to add anything to your Unity project by hand. The app
installs the Editor script it needs (`Assets/Editor/AddressablesModExporter.cs`)
automatically the first time it builds, and keeps it up to date afterwards.

## Download and install

Grab the installer for your OS from the
[latest release](https://github.com/MoSim-Modding-Fun/v25-Mod-Builder/releases/latest).

### Windows — `Mod Builder Installer Windows.msi`

Run the installer and follow the wizard (it lets you choose the install
location and whether to create Start Menu / desktop shortcuts). It installs
for your user only, so no administrator password is needed.

Windows SmartScreen will warn you that the publisher is unknown, because these
builds aren't code-signed. Click **More info → Run anyway**.

Re-running the installer later brings up the standard Windows
repair / uninstall / reinstall dialog.

### macOS — `Mod Builder Installer Mac.zip`

Unzip it and drag **V25 Mod Builder.app** into your Applications folder.

The app isn't signed by a registered Apple developer, so the first launch is
blocked. To get past it, **right-click the app → Open**, then click **Open**
in the dialog. You only have to do this once.

If macOS refuses entirely (or moves the app to the Trash), restore it from the
Trash, then run:

```bash
xattr -cr "/Applications/V25 Mod Builder.app"
```

and try opening it again. As a last resort, open **System Settings → Privacy
& Security** and look for an **Open Anyway** button near the bottom of the
page right after the block happens.

Requires macOS 13 (Ventura) or newer.

### Linux — `Mod Builder Installer Linux.pacman` or `.AppImage`

On **Arch, CachyOS, Manjaro** and other pacman-based distros, use the
`.pacman` package — it installs and runs with no extra setup:

```bash
sudo pacman -U "Mod Builder Installer Linux.pacman"
```

On **any other distro**, use the portable `.AppImage`. Make it executable
first, and note it needs `libfuse2` present:

```bash
chmod +x "Mod Builder Installer Linux.AppImage"
./"Mod Builder Installer Linux.AppImage"
```

## Using it

The app walks you through three pages.

**1. Select Unity Project.** Pick the root folder of your MoSimulator Unity
project. The app reads the Unity version it needs and lists every Addressable
group in the project, skipping Unity's own default groups and the bundled
example mods (`LynkMod`, `LynkModOfficial`, `MechTechMod`). This is instant —
selecting a project never launches Unity. Your choice is remembered for next
time.

**2. Unity Editor.** The app finds your Unity Hub install of the required
version automatically. If it can't, click **Browse for Unity Editor...** and
point it at your `Unity.exe` (Windows), `Unity.app` bundle (macOS), or `Unity`
binary (Linux). This is remembered too.

**3. Groups to build.** Tick the mod group(s) you want. Each ticked group gets
its own optional **Version** and **Zip name override** fields — use the zip
name override if you want the released file named something other than the
Addressable group name.

Click **DETECT NEW MODS** to list mod folders in your project that don't have
an Addressable group yet; they show up tagged `NEW`. Nothing is created just
by detecting them — a `NEW` mod only becomes a real Addressable group if you
tick it and build it, so mods you never build won't clutter your project.

**4. Platforms.** Windows, macOS and Linux are all ticked by default. Untick
any you don't need for this run.

**5. Build.** The app launches Unity in the background, once per selected
platform, and streams the log so you can watch progress. Each platform gets a
full Addressables build (unavoidable — the bundle naming settings are
project-wide), and the app confirms the expected `.zip` actually landed in
`Mods/` rather than just trusting Unity's exit code.

Unity can't open a project that's already open in the Editor. If yours is, the
app offers to close that Editor for you — declining just cancels the build. It
never touches Unity windows it didn't open itself.

If a platform fails, the run stops there and a **RETRY** button appears. Retry
rebuilds only what didn't succeed — the platform that failed plus any that
never got a turn. Platforms that already built keep their output and their
zips, so fixing one platform doesn't cost you a rebuild of the others.

## Troubleshooting

**"Unity Editor not found."** The required version probably isn't installed,
or lives outside the default Unity Hub location. Install it via Unity Hub, or
use **Browse for Unity Editor...** to point at it directly.

**A build fails only for one platform.** You're most likely missing that
platform's build support module in Unity Hub. Add it to your Unity Editor
install (Unity Hub → Installs → the gear icon → Add modules), then hit
**RETRY**.

**Where are my settings stored?** Your last project, any manual Unity Editor
path, and the output folder override are saved outside the app's install
folder, so they survive reinstalls:

| OS | Location |
| --- | --- |
| Windows | `%APPDATA%\v25-mod-builder\settings.json` |
| macOS | app preferences (`com.v25.modbuilder`) |
| Linux | `~/.config/v25-mod-builder/settings.json` |

If you used the older "MoSim Mod Builder" release, your settings are migrated
automatically on first launch.

**Where does the output go?** Into `Mods/<GroupName>/` inside your Unity
project, unless you set an output folder override.

## Source code

Everything that builds this app lives in [`app/`](app) — the Electron app
(Windows/Linux), the native macOS app, the bundled Unity Editor script, and
build/packaging instructions. See [`app/README.md`](app/README.md) if you want
to build it yourself or contribute.
