# Windows port — working plan

Decisions already made (see TODO.md): **separate repo** (`Media_player-windows`),
UI-only, consuming a **prebuilt `mediacored.exe`** released from this repo.
No GPL code may be copied in (JMP/FluentFin/Plezy are reference-only).

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
- [ ] Definition of done: window opens ✓, engine list loads ✓; **playing a
  real URL + hwdec-current=d3d11va still unverified** — needs the user's
  Plex/Jellyfin/SMB source configured in
  `%LOCALAPPDATA%\MediaPlayer\settings.json` (no onboarding UI yet).

## Milestone 2 — engine lifecycle — DONE 2026-08-12

- [x] EngineManager.cs: spawns `mediacored.exe --port 0`, parses `LISTEN`,
  Job Object KILL_ON_JOB_CLOSE (live-verified: force-killed app takes the
  engine with it), 20s watchdog, 3-attempt restart backoff,
  `%LOCALAPPDATA%\MediaPlayer\` for db.
- [x] Credentials: DPAPI-protected fields in settings.json (Settings.cs).

## Milestone 3 — the UI (the real work, ~4,400 lines of SwiftUI to re-imagine)

Build in this order, hitting the same endpoints the Mac app uses:
- [ ] Onboarding: Sign in with Plex (`/plex/pin/*` routes do the whole PIN
  flow — open the returned URL in the browser, poll), Jellyfin
  (`/jellyfin/users`, `/jellyfin/login`), or SMB form.
- [ ] Home: hero carousel + Continue Watching + Recently Added rows
  (`/library/movies`, `/library/shows`, `/library/episodes` — sort/group
  client-side exactly like BrowseView.swift does).
- [ ] Movies / TV Shows grids + search.
- [ ] Detail sheets: backdrop, ratings badges (`critic_rating`,
  `audience_rating`), season pills, episode stills, watched/star controls
  (`/plex/watched`, `/plex/rate`, `/jellyfin/*`).
- [ ] Player overlay: timeline with hover seek-preview (`/plex/preview`
  trickplay tiles), skip-intro button (`/plex/markers`), external subtitles
  (`/plex/subtitles` → `sub-add`), settings popover (tracks/speed/subs).
- [ ] Downloads: `/downloads/start|list|delete`, play local files.
- [ ] Settings: the five sections, mirroring SettingsView.swift.

## Milestone 4 — Windows-specific hardening

- [ ] HDR passthrough: needs Windows HDR mode on + `d3d11` swapchain in
  HDR; `target-colorspace-hint=yes` mostly works on recent mpv — test on a
  real HDR display, expect edge cases (JMP's issue tracker is a good map of
  what goes wrong — read, don't copy).
- [ ] Multi-monitor DPI, fullscreen behavior, media keys
  (`SystemMediaTransportControls` for play/pause from keyboard).

## Milestone 5 — packaging

- [ ] Inno Setup installer (simplest) bundling exe + mpv-2.dll +
  mediacored.exe + LGPL license texts. MSIX later if Store distribution
  (Store registration is free now).
- [ ] Authenticode signing (~$120–230/yr) can wait — unsigned means a
  SmartScreen warning, acceptable during development.

## What NOT to do

- Don't copy code from Jellyfin Media Player, FluentFin, Plezy (GPL).
- Don't fork this repo for it. Don't publish mediacore to crates.io — the
  exe artifact is the interface.
- Don't start with HDR or downloads — a window that plays SDR video from
  the library API is the first dopamine hit; everything else stacks on it.
