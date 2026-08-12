# Windows port — working plan

Decisions already made (see TODO.md): **separate repo**, UI-only, consuming a
**prebuilt `mediacored.exe`** released from this repo. No GPL code may be
copied in (JMP/FluentFin/Plezy are reference-only).

The repo now exists: **[windows_media_player](https://github.com/as-alsaleh/windows_media_player)**
(MIT, Avalonia/.NET 10) and ships releases:

    wget https://github.com/as-alsaleh/windows_media_player/releases/latest/download/mediaplayer-windows-x64.zip

Milestones 0–4 are done and 5 is shipping. What's left needs hardware or
server configuration rather than code: HDR passthrough on a display with
Windows HDR enabled, and seek previews (Plex must have "Generate video
preview thumbnails" on). An installer and code signing remain optional.

The engine does all the hard work already — Plex/Jellyfin/SMB, library merge,
watch state, downloads, trickplay, ratings — over localhost HTTP. The Windows
app is "a window with mpv in it + the UI" talking to `http://127.0.0.1:{port}`.

## Milestone 0 — build the engine for Windows (start here) — DONE 2026-08-12

- [x] Toolchain installed. Note: the MSVC Build Tools installer needs a UAC
  prompt that unattended sessions can't answer — the working no-admin
  alternative is `rustup toolchain install stable-gnu` + portable WinLibs
  gcc (extracted zip, in `%LOCALAPPDATA%\mingw-extract\mingw64\bin`), then
  `cargo build --target x86_64-pc-windows-gnu`. CI uses MSVC normally.
- [x] Built: **zero code changes needed**, exactly as predicted (no
  `#[cfg(target_os)]`, pure-Rust SMB, bundled SQLite, rustls/ring).
  `cargo test`: all 17 pass on Windows.
- [x] Smoke test (scratch db, no sources): `LISTEN` prints, `/library/movies`
  and `/library/shows` answer 200. *Against the real Plex server: pending —
  needs the user's token on the Windows machine.*
- [x] Path handling verified: Windows `\` paths in `--db` work (std::path
  throughout); SMB stays forward-slash by protocol (`stem()` in index.rs
  only ever sees SMB paths).
- [x] GitHub Actions workflow added
  ([mediacored-windows.yml](.github/workflows/mediacored-windows.yml)):
  build + test on `windows-latest`, artifact upload, release attach on
  `core-v*` tags:

      # .github/workflows/mediacored-windows.yml
      name: mediacored-windows
      on: { push: { tags: ["core-v*"] }, workflow_dispatch: {} }
      jobs:
        build:
          runs-on: windows-latest
          steps:
            - uses: actions/checkout@v4
            - run: cargo build --release --bin mediacored
              working-directory: core/mediacore
            - uses: actions/upload-artifact@v4
              with: { name: mediacored-windows-x64, path: core/mediacore/target/release/mediacored.exe }

## Milestone 1 — mpv renders in a window — code in place 2026-08-12

- [x] `Media_player-windows` repo created fresh at
  `C:\Users\Admin\Desktop\Media_player-windows` (MIT).
- [x] libmpv: shinchiro `libmpv-2.dll` in `libs/`, dynamic linking.
- [x] Framework: **Avalonia (C#)**, .NET 10.
  - Native-feeling enough, XAML-like, one codebase later covers Linux too.
  - mpv embeds via `NativeControlHost` handing the HWND to `wid`.
  - Alternative if you want maximum native feel: WinUI 3 (SwiftUI-like
    idioms, Windows-only, heavier tooling). Either works; don't overthink.
- [x] mpv wired per MPVPlayer.swift (MpvPlayer.cs): full option block with
  the three platform swaps (HWND wid, d3d11, d3d11va), all six property
  observers, transient-error retry, track/chapter/subtitle plumbing.
- [x] **Definition of done met** (2026-08-12): plays a direct URL from
  `/library/movies`, seek + pause work, and `hwdec-current=d3d11va` with
  gpu-next on the d3d11 backend (verified on an RTX 5070, feature level
  12_1). `MediaPlayer.Windows.exe <url>` is the headless test hook.
- Note: mpv's native child HWND paints over all Avalonia content and `wid`
  can't be rebound, so the host lives in the tree permanently (row collapsed
  to zero while browsing) and the transport controls are a separate owned
  window tracking the main window.

## Milestone 2 — engine lifecycle — DONE 2026-08-12

- [x] EngineManager.cs: spawns `mediacored.exe --port 0`, parses `LISTEN`,
  Job Object KILL_ON_JOB_CLOSE (live-verified: force-killed app takes the
  engine with it), 20s watchdog, 3-attempt restart backoff,
  `%LOCALAPPDATA%\MediaPlayer\` for db.
- [x] Credentials: DPAPI-protected fields in settings.json (Settings.cs).

## Milestone 3 — the UI — DONE 2026-08-12

Live-verified against the user's Plex server on the Kids profile: 24 movies,
7 shows, 847 episodes, 7 hero slides, 7 Continue Watching, 15 Recently Added.
- [x] Onboarding: Plex PIN flow (browser + poll), Jellyfin user tiles, SMB form.
- [x] Home: hero slideshow (7s auto-advance, dots, edge chevrons), Continue
  Watching, Recently Added, Movies and TV Shows carousels.
- [x] Movies / TV Shows grids + search.
- [x] Detail sheets: backdrops, rating badges, resume bars, star ratings,
  watched toggles, season pills, episode rows with stills and synopses.
- [x] Player overlay: timeline, skip-intro from `/plex/markers`, external
  subtitles via `sub-add`, track pickers, speed/volume/sub-scale/sync
  popover, next-episode chaining. *Trickplay seek-preview (`/plex/preview`)
  is the one piece not yet built.*
- [x] Downloads: `/downloads/start|list|delete`, play from disk.
- [x] Settings: playback, languages, Plex, Jellyfin, SMB, metadata keys.
- [x] Extras beyond the plan: SMB file browser (BrowserView port), Plex Home
  profile switching with PIN prompts, and restricted-profile gating that
  hides Files/Downloads for Kids profiles.

## Milestone 4 — Windows-specific hardening — mostly done 2026-08-12

- [x] HDR handled adaptively. `target-colorspace-hint=yes` was wrong as a
  constant: it hands a PQ signal to SDR displays too. It now defaults to
  `auto` (passthrough only when Windows HDR is actually on) with a Settings
  override, and `hdr-compute-peak` is skipped when passing through since
  its only consumer is tone mapping. A `HdrStatus` DisplayConfig probe
  reports supported/enabled/bit-depth, re-queried per load because
  Win+Alt+B can flip it mid-session.
  *Passthrough itself is still unverified on real hardware* — the test
  machine's display reports HDR-capable but has HDR switched off, so only
  the tone-mapping and forced-passthrough paths have been exercised.
- [x] Media keys via `RegisterHotKey` + a WndProc hook. (`SystemMediaTransportControls`
  would also give the OS media flyout, but needs a WinRT TFM — worth
  revisiting if the flyout is wanted.)
- [x] Per-monitor DPI v2 declared in the app manifest; fullscreen verified.

## Milestone 5 — packaging — shipping 2026-08-12

- [x] **Releases are live**: `scripts/bundle.ps1` publishes a self-contained
  zip (no .NET/mpv/Rust needed on the target) with the third-party license
  texts and a SHA256; CI runs it on a `v*` tag and attaches it to a GitHub
  Release. Verified by downloading the published artifact and checking the
  hash. v0.1.0 and v0.1.1 are out.
  - While this repo is private, the Windows repo vendors a prebuilt
    `mediacored.exe`; the workflow switches to building it from source as
    soon as a `CORE_REPO_TOKEN` secret exists or this repo goes public.
- [ ] Inno Setup installer — optional now that the zip is self-contained;
  worth it for Start-menu entries and file associations.
- [ ] Authenticode signing (~$120–230/yr). Unsigned means a SmartScreen
  warning; each release publishes a checksum in the meantime.

## What NOT to do

- Don't copy code from Jellyfin Media Player, FluentFin, Plezy (GPL).
- Don't fork this repo for it. Don't publish mediacore to crates.io — the
  exe artifact is the interface.
- Don't start with HDR or downloads — a window that plays SDR video from
  the library API is the first dopamine hit; everything else stacks on it.
