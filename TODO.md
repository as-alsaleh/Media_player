# TODO

Derived from an audit of what's built vs. what's wired up, plus the README
roadmap. The source has no TODO/FIXME markers — these came from comparing the
Rust engine's surface against what the Swift apps actually call.

## Apple — feature gaps

- [x] **Wire up Trakt, or delete it.** Deleted — Trakt now requires paid VIP to
  register API apps, so the decision was to skip it entirely. `trakt.rs`, its
  routes and handlers are removed.
- [x] **Settings entry point on iOS/tvOS.** The shared `BrowseView` gear was
  already live on all platforms (verified in the iPhone simulator); what was
  missing was a route from onboarding — added "Or connect an SMB share in
  Settings" beneath the sign-in buttons.
- [x] **iOS SMB password into the Keychain.** iOS now uses `ShareStore`
  (Keychain) like macOS, migrates legacy plaintext config on first run and
  scrubs the old default. The plaintext dev-build escape hatch is macOS-only.
- [x] **Jellyfin feature parity with Plex.** Added `/jellyfin/markers` (media
  segments → intro/credits/commercial), `/jellyfin/subtitles` (external text
  streams via the subtitle delivery URL) and `/jellyfin/rate` (0–10 mapped to
  likes; 0 clears). Both apps fetch markers/subtitles for `jf:` items and the
  detail-sheet watched/star controls now drive Jellyfin too. `/preview`
  (trickplay) already existed. *Live verification pending — the Jellyfin
  container on the mini PC is stopped at the user's request; code compiles and
  mirrors the verified Plex path.*
- [x] **Show critic/audience ratings.** Plex `rating`/`audienceRating` and
  Jellyfin `CriticRating`/`CommunityRating` are parsed, served on
  `/library/movies` and `/library/shows`, and shown as rosette/audience badges
  in the movie and show detail sheets (verified live: 78/82 movies had RT
  scores). OMDb fallback for the SMB-only library remains open.
- [x] **Offline downloads.** `downloads.rs` streams the source URL into
  `…/MediaPlayer/Downloads` with a JSON manifest (`/downloads/start`, `/list`,
  `/delete`); interrupted transfers surface as errors on restart. Movie detail
  sheets have a download button, the nav bar a Downloads sheet with live
  progress, play-from-disk and delete. Progress keys carry over, so resume
  points work offline. Verified end-to-end: 379 MB episode downloaded and
  played back from disk with its resume point. Per-episode download buttons
  added to the show sheet (verified live). Remaining follow-up: poster
  caching for fully-offline artwork.
- [ ] **Emby source.** *Deferred — needs an Emby instance to verify against.*
  `jellyfin.rs` already sends `X-Emby-Authorization` and the endpoints used
  (auth, items, sessions, played-items, media segments, subtitles) are
  API-compatible on Emby, so this is likely config-only when a server exists.
- [x] **tvOS remote polish.** Verified in the Apple TV 4K simulator with the
  virtual Siri Remote: focus moves across tabs/hero/cards, select plays with
  resume, video renders (gpu-next over MoltenVK), and the player now handles
  the remote properly — Menu hides controls then exits (`onExitCommand`),
  play/pause button works (`onPlayPauseCommand`), left/right seek by the
  configured skip amounts, down reveals controls. The pass also flushed out
  two real bugs, both fixed: `rustls-tls-native-roots` alone left iOS/tvOS
  with zero CAs (every TLS fetch silently failed — webpki snapshot re-added
  as fallback), and a stale SMB credential hard-killed the whole engine even
  when Plex/Jellyfin could serve (now degrades with a warning). Remaining
  nice-to-have: hero paging directly from the remote.

## Apple — hardening

- [x] **Merge `harden-frozen-builds`.** Merged; compiles on all three platforms
  and `cargo test` passes with `rustls-tls-native-roots`.
- [x] **Surface `initError` in the player UI.** The player overlay now shows a
  "Playback engine failed to start" card with the mpv error and a Close button.
- [x] **Fetch the TMDB image base from `/configuration`.** Read once per
  enrich() run from `images.secure_base_url`, falling back to the documented
  host when unreachable.
- [x] **Verify Plex failure degradation.** `unreachable_server_degrades_to_empty`
  tests (Plex and Jellyfin) hit a dead localhost port and assert every aux call
  degrades to empty/None/false rather than erroring; the apps already treat
  those as absence. Live playback from a downloaded file exercised the same
  code path end-to-end.
- [x] **Expand Rust test coverage (first pass).** 9 tests now: Plex metadata
  parsing (ratings, guids, markers, minimal payloads), Jellyfin item parsing
  (ratings, ticks, provider ids), `iso_to_epoch`, trickplay widest-grid
  selection, and the `norm()` dedup key, plus the existing parse/range tests.
  `smb.rs` and `index.rs` still lack coverage.
- [x] **MPL Exhibit A headers.** Resolved as won't-do: the repo relies on the
  LICENSE file, which MPL-2.0 explicitly permits.

## Apple — shipping

- [ ] **Notarized DMG pipeline.** *Blocked on the user: needs an Apple
  Developer ID certificate ($99/yr membership).*
  `bundle-macos.sh` produces an `.app` with no signing, notarization, stapling
  or DMG. Turns "install Rust and Xcode, then build" into "download and run".
  Developer ID certs last 5 years and notarization tickets don't expire, so one
  notarized build outlives a lapsed membership. Bundle the MPVKit LGPL texts.
- [ ] **iOS device signing in `project.yml`.** *Blocked on the user: needs
  their Apple `DEVELOPMENT_TEAM` id.* When available, set it plus
  `CODE_SIGNING_ALLOWED: "YES"` in `project.yml` (not the Xcode UI — XcodeGen
  regenerates and wipes UI config).
- [x] **Bring-your-own TMDB key in settings.** Settings → Files has a "TMDB
  (Artwork for SMB Libraries)" card writing the `tmdbApiKey` default the
  engine already reads, with the terms note.
- [x] **App Store submission materials.** Drafted in
  [docs/app-store.md](app-store.md): metadata, description, privacy label,
  review-notes template with demo-server guidance, licensing position and a
  submission checklist. Only the demo server itself and the paid membership
  remain.

## Windows port

Ordered by difficulty. **Reconsider the UI rewrite before starting any of
this** — Plezy already covers Windows with Plex + Jellyfin + mpv, and that item
is ~80% of the total effort.

### Repo strategy: a new repo, not a fork

Decided: the Windows UI lives in its own repository (`Media_player-windows`),
created fresh — not a GitHub fork. A fork drags along the `apps/macos` and
`apps/ios` trees that will never compile there, and defaults its PRs upstream.

The reason it must be separate is **licensing**. Same repo means same LICENSE.
Pasting GPL code from Jellyfin Media Player or FluentFin into a Windows UI is
completely fine on Windows — there's no App Store involved — but if it lives
alongside `mediacore`, it argues for relicensing the core and kills the Apple
App Store path permanently. Separate repos make that structurally impossible
instead of a rule someone has to remember.

No submodule or crates.io publish is needed: `mediacore` is already a localhost
HTTP API, so the Windows repo consumes a **prebuilt `mediacored.exe`** released
as a build artifact from this repo. Zero source coupling.

    Media_player          → Rust core + Apple apps (MPL-2.0), builds mediacored.exe
    Media_player-windows  → UI only, ships the prebuilt mediacored.exe

Cost: changes spanning both (new endpoint + its consumer) become two commits in
two repos. Minor — there's a release boundary either way.

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
