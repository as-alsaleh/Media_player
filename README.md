# MediaPlayer

Open-source, Infuse-style media player for Apple platforms: hardware-decoded 4K HDR
playback of high-bitrate MKV/REMUX files streamed directly from network shares.

## Architecture

```
SwiftUI app (macOS first; iOS/tvOS later)
 ├── PlayerView ── libmpv (MPVKit) ── Metal render, VideoToolbox hwdec, libass, PGS
 ├── FileBrowser
 │        │ FFI (UniFFI)
 │        ▼
 └── mediacore (Rust)
        ├── SMB client (async, tokio)
        ├── loopback HTTP streamer (Range requests → mpv plays http://127.0.0.1:PORT/…)
        └── (M2) indexer: SQLite + TMDB
```

- **Playback core:** [libmpv](https://mpv.io) via [MPVKit](https://github.com/mpvkit/MPVKit)
  — zero-copy VideoToolbox decoding, gpu-next/libplacebo tone mapping (HDR10, DV P5/P8),
  AV sync, libass and PGS subtitle rendering out of the box.
- **Network layer:** Rust crate `core/mediacore` exposes network files to mpv through a
  localhost HTTP server with Range support instead of mpv's stream plugin API.

## Layout

| Path | Purpose |
|---|---|
| `apps/macos/` | SwiftUI macOS app |
| `core/mediacore/` | Rust workspace: SMB client, streamer, FFI |
| `docs/` | Design notes |
| `scripts/` | Build orchestration (cargo → xcframework → Xcode) |

## Milestones

- **M0** — local-file playback via MPVKit, basic controls, hwdec verification
- **M1** — SMB browsing + streaming (Rust core, loopback streamer)
- **M2** — library: SQLite index, TMDB metadata, artwork, watch state
- **M3** — iOS/tvOS, audio passthrough research, NFS/WebDAV

## Prerequisites

- Full Xcode (not just Command Line Tools): `xcode-select -s /Applications/Xcode.app`
- Rust: `curl https://sh.rustup.rs -sSf | sh`

## License

GPL-2.0-or-later (required by the libmpv/FFmpeg dependency chain).
