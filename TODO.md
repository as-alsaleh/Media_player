# TODO

Derived from an audit of what's built vs. what's wired up, plus the README
roadmap. The source has no TODO/FIXME markers — these came from comparing the
Rust engine's surface against what the Swift apps actually call.

## Apple — feature gaps

- [ ] **Wire up Trakt, or delete it.** `core/mediacore/src/trakt.rs` implements
  device auth, token exchange and scrobbling, and `streamer.rs` registers
  `/trakt/login/start`, `/trakt/login/poll`, `/trakt/scrobble`. Nothing in
  `apps/` references Trakt at all — the whole integration is unreachable.
- [ ] **Settings entry point on iOS/tvOS.** `iOSApp.swift` shows
  `OnboardingView` when unconfigured and `BrowseView` once configured, with no
  route to `SettingsView` — even though `project.yml` compiles it into both
  targets. After first run you can't change server, sign out or switch accounts.
- [ ] **iOS SMB password into the Keychain.** Currently
  `@AppStorage("smbPassword")` — plain UserDefaults. macOS does this correctly
  via `ShareStore.swift` and Security.framework.
- [ ] **Jellyfin feature parity with Plex.** Plex has `/markers`, `/subtitles`,
  `/preview` and `/rate`; Jellyfin only has `/users`, `/login`, `/progress`,
  `/watched`. No skip-intro, trickplay, subtitle listing or ratings on Jellyfin.
- [ ] **Offline downloads.** README roadmap. No download routes, no local media
  store, no UI. Needs a download endpoint, a completed-downloads index,
  playback from local path, and manage/delete UI.
- [ ] **Emby source.** README roadmap. `jellyfin.rs` already sends
  `X-Emby-Authorization`, so much of the client may be reusable.
- [ ] **tvOS remote polish.** README roadmap. The shared UI was built
  mouse/trackpad-first — `BrowseView.swift:546` is an `NSEvent` scroll catcher
  with no tvOS equivalent. Needs a focus-engine pass.

## Apple — hardening

- [ ] **Merge `harden-frozen-builds`.** Pushed, unmerged, uncompiled. Contains
  the `rustls-tls-native-roots` change and the `mpv_initialize` fallback.
- [ ] **Surface `initError` in the player UI.** `MPVPlayer` sets it when both
  render passes fail; nothing reads it, so a total init failure is still a
  black window.
- [ ] **Fetch the TMDB image base from `/configuration`.** `tmdb.rs:6`
  hardcodes `https://image.tmdb.org/t/p`. TMDB documents that clients should
  read it, precisely so they can move the CDN.
- [ ] **Verify Plex failure degradation.** Parsing is already tolerant (`Option`
  fields, `serde(default)`, no `deny_unknown_fields`). Untested is *behaviour*:
  stub markers/preview/subtitles/rate to fail and confirm playback still works.
- [ ] **Expand Rust test coverage.** Three tests exist in the whole core (two in
  `parse.rs`, one in `streamer.rs`). Nothing covers `plex.rs` (708 lines),
  `jellyfin.rs` (481), range handling in `streamer.rs`, `smb.rs` or `index.rs`.
- [ ] **MPL Exhibit A headers.** Optional; ~22 files. MPL explicitly allows
  relying on the LICENSE file instead.

## Apple — shipping

- [ ] **Notarized DMG pipeline.** *Highest-leverage item on this list.*
  `bundle-macos.sh` produces an `.app` with no signing, notarization, stapling
  or DMG. Turns "install Rust and Xcode, then build" into "download and run".
  Developer ID certs last 5 years and notarization tickets don't expire, so one
  notarized build outlives a lapsed membership. Bundle the MPVKit LGPL texts.
- [ ] **iOS device signing in `project.yml`.** Both targets set
  `CODE_SIGNING_ALLOWED: "NO"`, which blocks device installs. Set it in
  `project.yml`, not the Xcode UI — XcodeGen regenerates and wipes UI config.
- [ ] **Bring-your-own TMDB key in settings.** `tmdb_key` is already
  `Option<String>` injected at runtime. Making it explicit keeps TMDB's
  non-commercial terms the user's obligation and preserves the option to charge
  later without triggering their commercial license.
- [ ] **App Store submission materials.** Demo server + credentials in review
  notes (reviewers can't test a client with no server — the most common
  rejection for this category); privacy label "Data Not Collected"; describe it
  as "connect to your Plex or Jellyfin server", not "watch movies and TV".

## Windows port

Ordered by difficulty. **Reconsider #21 before starting any of this** — Plezy
already covers Windows with Plex + Jellyfin + mpv, and the UI rewrite is ~80%
of the total effort.

- [ ] **Verify `cargo build --target x86_64-pc-windows-msvc`.** Should be close
  to free: zero `#[cfg(target_os)]` in the core, pure-Rust `smb` crate, bundled
  rusqlite, rustls rather than OpenSSL. Needs MSVC build tools.
- [ ] **Path separators in `index.rs` / `parse.rs`.** SMB stays forward-slash;
  Windows local paths don't.
- [ ] **Source libmpv for Windows.** MPVKit is Apple-only. Use `mpv-2.dll`
  (shinchiro builds) or build with meson. Dynamic linking, LGPL texts shipped.
- [ ] **Port the render surface.** `CAMetalLayer` → `HWND` in `wid`,
  `gpu-api=vulkan` → `d3d11`, `hwdec=videotoolbox` → `d3d11va`. Every quality
  option carries over unchanged — that's all libplacebo.
- [ ] **Keychain → Credential Manager / DPAPI.** ~50 lines, security-sensitive.
- [ ] **Port the `mediacored` helper launch.** `StreamerManager.swift:56` spawns
  it via `Process`; Windows needs `mediacored.exe` lookup plus `%LOCALAPPDATA%`
  for the database. Direct port — the daemon model is already the macOS design.
- [ ] **HDR passthrough.** Fiddlier than macOS: needs OS HDR mode enabled, and
  `target-colorspace-hint` through D3D11 has more edge cases. Jellyfin Media
  Player solves this already — read it, don't copy (GPL).
- [ ] **Packaging and code signing.** MSIX/WiX/Inno installer; Authenticode
  signing (~$120–230/yr) or SmartScreen scares users off. Microsoft Store
  registration is free as of 2026.
- [ ] **Rewrite the UI — ~4,400 lines of SwiftUI.** The hard part. SwiftUI is
  Apple-only with no port. WinUI 3 for native feel, Avalonia to also cover
  Linux. Not mechanical: the hero carousel, season pills, episode stills and
  player overlay are design work re-executed. **Keep it in a separate repo** so
  GPL code a contributor pulls from JMP/FluentFin can't contaminate the MPL core.
