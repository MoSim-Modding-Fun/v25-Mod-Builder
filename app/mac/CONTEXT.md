# Context for continuing this project on macOS

This file exists so a Claude session running on your MacBook has full context
without needing the original chat transcript (there's no tool to export that
directly — this is a written summary of everything relevant instead).

## The three repos/projects involved

1. **MoSim-Reefscape-Public** — the actual Unity project (MoSimulator). Contains
   `Assets/Editor/AddressablesModExporter.cs`, a custom Editor script that builds
   selected Addressable mod groups (per platform) and zips the result into
   `Mods/<GroupName>/`. Both GUI tools below just launch Unity headless with
   `-executeMethod Editor.AddressablesModExporter.BuildFromCommandLine` — neither
   reimplements the actual build logic. You need a local checkout of this repo
   (or any repo with that same Editor script) to actually use either GUI tool.

2. **v25 Mod Builder** (Electron, Windows/macOS/Linux) — the original
   cross-platform GUI. It lives **one level up from this `mac/` folder**, in
   the repo's `app/` directory (`main.js`, `renderer/`, `package.json`, etc.
   all live there; the repo root itself holds only `README.md` and `.github/`).
   Fully working on Windows (verified via GitHub Actions CI). This is the
   "spec" this native app is porting: same workflow, same visual design
   (Rufus-style light theme with a wizard flow), same Unity CLI invocation.

3. **`mac/` (this folder)** — a **from-scratch native Swift/SwiftUI rewrite**,
   macOS-only, started specifically to work around a Gatekeeper problem the
   Electron build couldn't solve (see below). Shares no code with the Electron
   app — it's a parallel implementation of the same workflow, living inside
   the same repo as a sibling to the Electron app's own source.

## Why this native app exists

The Electron app's macOS build (`Mod Builder Installer Mac.dmg`) kept getting
**deleted outright** by macOS with a "Malware Blocked and Moved to Trash"
dialog, not just the milder "unidentified developer" warning. Troubleshooting
history, in order:

1. Unsigned build → hit the harsh malware-block dialog.
2. Added ad-hoc signing (`identity: "-"`, `hardenedRuntime: false` in the
   Electron app's `package.json`) — did **not** fix it.
3. Tried `xattr -cr` to strip the quarantine attribute after the block — did
   **not** fix it either.
4. Conclusion: this is macOS's **XProtect** background malware scanner (not
   the standard Gatekeeper/notarization check, which ad-hoc signing and
   `xattr` *do* address). XProtect scans file content independent of the
   quarantine attribute, and Electron apps get disproportionately flagged
   because so much real malware (fake crypto wallets, fake meeting apps) is
   built with Electron — the bundled Chromium+Node structure has a recognizable
   fingerprint.
5. Real Apple notarization would fix this for certain, but requires a paid
   Apple Developer Program membership ($99/year) — **not affordable right
   now**, explicitly declined multiple times when offered.
6. Decision: build a **native app instead**, on the hypothesis that removing
   the Electron/Chromium/Node fingerprint reduces (does not guarantee zero)
   risk of the same XProtect false-positive. This is genuinely unverified —
   there's no way to confirm until it's actually tested on a Mac.

**This app is still unsigned and unnotarized.** It may still need ad-hoc
signing added (`codesign --sign -`) to run at all on Apple Silicon, and may
still trigger *some* Gatekeeper prompt (the milder "unidentified developer"
one is expected and fine — the goal was only to avoid the instant-delete
malware-tier block).

## ⚠️ Critical: none of this Swift code has been compiled or run

The session that wrote this app runs in a **Windows sandbox with no macOS, no
Xcode, and no Swift toolchain available**. Every file was hand-written from
Swift/SwiftUI/Foundation knowledge with no compiler feedback loop at all —
unlike the Electron app (where CI errors got pasted back and fixed
iteratively), this has had zero verification passes.

**What to do:** open `Package.swift` in Xcode (this is a Swift Package with an
executable target containing a SwiftUI `@main App` — Xcode can open and run it
directly via "Open..." on `Package.swift`, no `.xcodeproj` needed). Build it,
and if it fails, paste the exact compiler errors back to Claude — that's the
same iterate-on-real-errors loop that got the Electron app's CI working.
Expect at least a few rounds of this; treat the first build as a draft, not a
near-final product.

## Architecture

```
Package.swift
Sources/V25ModBuilder/
  App.swift            @main entry point
  Models.swift          ModGroup, PlatformTarget, ProgressSegment, ConsoleLine
  ProjectService.swift  Project validation, group listing, Unity path detection
  AppState.swift        ObservableObject: all cross-page state + UserDefaults persistence
  BuildRunner.swift      Spawns Unity, tails the log live, parses progress, moves output
  Theme.swift            Colors + custom button/groupbox styles matching the Electron app
  ContentView.swift      Wizard shell: step dots + Back/Next/Start/Close bar
  ProjectPage.swift      Page 1: project + Unity Editor selection
  GroupsPage.swift       Page 2: groups, platforms, output folder, zip-name preview
  BuildPage.swift        Page 3: status pills, progress bar, per-platform console tabs
```

Every piece of business logic (project validation rules, reserved group names
to exclude, Unity CLI arguments, log-line parsing for progress, output-move
logic, zip filename computation) is a **direct port** of the Electron app's
`main.js`/`renderer.js` — read those files in `app/` (`../main.js`,
`../renderer/renderer.js` relative to this folder) if anything here is
ambiguous; they're the source of truth for *what* the behavior should be,
this Swift code is just a different *how*.

### Reserved (excluded) Addressable group names
`Built In Data`, `EditorSceneList`, `Default Local Group`, `LynkMod`,
`MechTechMod` — the last two are example/template mods bundled in the Unity
repo, not real distributable content.

### Settings persistence
Uses `UserDefaults` (native, idiomatic) instead of the Electron app's
hand-rolled `settings.json` — same three values though: project path, Unity
path override, output folder override.

## Known deliberate simplifications (vs. the Electron app)

- **Console auto-scroll**: always follows new output to the bottom. The
  Electron app only auto-follows while already at the bottom, and shows a
  "jump to bottom" button once you've scrolled up to read something.
  Replicating that precisely needs either macOS 14's `.scrollPosition` API or
  a custom `NSScrollView` wrapper — skipped for now since it couldn't be
  tested; the always-follow behavior is simpler and more likely to compile
  correctly on a first pass. Worth revisiting once the app actually builds.
- **Font**: system font instead of Segoe UI (not available on macOS). Colors,
  borders, and layout otherwise match the Electron app's CSS pixel-for-pixel
  where feasible.
- **No app icon wired in yet** — the Electron app's `logo.png`/`build/icon.png`
  exist in `app/` (`../logo.png`, `../build/icon.png` relative to this
  folder) and could be dropped into an `Assets.xcassets` AppIcon set once this
  is opened in Xcode.
- **No code signing configured yet** for this app either. At minimum it'll
  likely need ad-hoc signing to launch on Apple Silicon — Xcode may handle
  this automatically for local development builds; for actual distribution
  this needs revisiting.

## Other context from the Electron app's build/release setup

(Not directly relevant to the Swift code, but useful background if asked to
touch the Electron app or its CI while working from this checkout.)

- **`AddressablesModExporter.cs` bug fixed this session**: the "zip name
  override" feature used to rename the *internal* folder inside the zip to
  match the branding name, which broke the game's runtime `LoadPath` (baked
  into the catalog based on the actual Addressable **group name**, not the
  branding name). Fixed so only the *outer* `.zip` filename uses the branding
  override; the internal folder always matches the group name.
- **Windows installer**: uses `electron-builder`'s `msi` target (not NSIS)
  specifically to get native Windows Installer repair/uninstall/reinstall
  maintenance-mode detection on re-run. `perMachine: false` (per-user install,
  no admin required, at the user's request).
- **GitHub Actions** (`.github/workflows/build-installers.yml`, at the repo
  root — GitHub only reads workflows from there, which is why `.github/` did
  not move into `app/`): triggers **only** on pushed tags matching `v*.*.*` — not on ordinary
  pushes/PRs. Builds all three platforms, uploads as artifacts, and on tag
  pushes also creates a GitHub Release with all three installers attached.
  Had to fix: `electron-builder --publish never` (it was trying to
  self-publish and needed a token we don't provide), bumped
  `actions/checkout`/`actions/setup-node` to v5 for a Node-version deprecation
  warning, added a `msi` config that must be a **top-level `build.msi` block**,
  not nested under `build.win` (schema validation rejected that placement).
- **Windows taskbar icon was blurry**: fixed by pre-rendering all 8 standard
  icon sizes (16 through 256) from the source PNG and packaging them into
  `build/icon.ico` via a `scripts/generate-icon.mjs` script (`npm run icon`) —
  `png-to-ico`'s own auto-resize only produced 4 sizes, causing Windows to
  upscale the nearest smaller frame for sizes it needed but didn't have.
