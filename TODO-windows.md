# Windows port — working plan

Decisions already made (see TODO.md): **separate repo** (`Media_player-windows`),
UI-only, consuming a **prebuilt `mediacored.exe`** released from this repo.
No GPL code may be copied in (JMP/FluentFin/Plezy are reference-only).

The engine does all the hard work already — Plex/Jellyfin/SMB, library merge,
watch state, downloads, trickplay, ratings — over localhost HTTP. The Windows
app is "a window with mpv in it + the UI" talking to `http://127.0.0.1:{port}`.

## Milestone 0 — build the engine for Windows (start here)

- [ ] On the Windows machine: install [rustup](https://rustup.rs) (defaults to
  MSVC toolchain) + "Visual Studio Build Tools" C++ workload.
- [ ] Clone THIS repo, then:

      cd core/mediacore
      cargo build --release --bin mediacored

  Expected to just work: no `#[cfg(target_os)]` anywhere, pure-Rust SMB,
  bundled SQLite, rustls (no OpenSSL). Fix whatever doesn't compile — commit
  those fixes to this repo, not the Windows one.
- [ ] Smoke test — run it against the mini PC and curl the API:

      set MEDIACORED_PLEX_TOKEN=<token>
      target\release\mediacored.exe --port 8484 --db %LOCALAPPDATA%\MediaPlayer\library.sqlite --plex-url https://<server>:32400
      curl http://127.0.0.1:8484/library/movies

- [ ] Check path handling: SMB paths stay forward-slash (fine), but
  `--db` and the Downloads dir use `\` — verify `index.rs`/`downloads.rs`
  behave with Windows paths (they use std::path, so likely fine; test).
- [ ] Optional but recommended: add a GitHub Actions workflow to this repo
  that builds `mediacored.exe` on a `windows-latest` runner and attaches it
  as a release artifact, so the Windows repo never needs Rust installed:

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

## Milestone 1 — mpv renders in a window

- [ ] Create the `Media_player-windows` repo (fresh, not a fork). License:
  anything you like — MIT keeps contributions easy; GPL is also fine here
  *because it's a separate repo* (that was the whole point of the split).
- [ ] Get libmpv: shinchiro's `mpv-dev-x86_64` builds (libmpv-2.dll +
  headers) — ship the DLL beside the exe, dynamic linking (LGPL-clean).
- [ ] Framework choice — recommendation: **Avalonia (C#)**.
  - Native-feeling enough, XAML-like, one codebase later covers Linux too.
  - mpv embeds via `NativeControlHost` handing the HWND to `wid`.
  - Alternative if you want maximum native feel: WinUI 3 (SwiftUI-like
    idioms, Windows-only, heavier tooling). Either works; don't overthink.
- [ ] Wire mpv exactly like the Mac app does (MPVPlayer.swift is the spec):
  - options before init: `wid=<HWND>`, `vo=gpu-next`, `gpu-api=d3d11`,
    `hwdec=d3d11va`, then the same quality block (tone-mapping=spline,
    hdr-compute-peak, gamut-mapping-mode=perceptual, deband, scalers,
    cache/demuxer settings). Every libplacebo option carries over unchanged.
  - property observers: pause, time-pos, duration, hwdec-current, eof.
- [ ] Definition of done: window opens, plays a direct URL from
  `/library/movies`, seek + pause work, hw decode confirmed
  (`hwdec-current` = d3d11va).

## Milestone 2 — engine lifecycle

- [ ] Port `StreamerManager.start()` (StreamerManager.swift is the spec):
  spawn `mediacored.exe --port 0 ...` as a child process, read the chosen
  port from its stdout line, kill it on app exit (Job Object so it dies with
  the app), `%LOCALAPPDATA%\MediaPlayer\` for db + downloads.
- [ ] Credentials: SMB password + tokens go in Windows Credential Manager
  (`CredWrite`/`CredRead` — the ShareStore.swift equivalent, ~50 lines).
  Plex/Jellyfin tokens in app settings (DPAPI-protected file is fine too).

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
