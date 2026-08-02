# App Store submission kit

Everything reviewers and App Store Connect will ask for, ready to paste.
Blocked only on an Apple Developer membership ($99/yr) and a demo server.

## App Store Connect metadata

**Name:** MediaPlayer — for Plex & Jellyfin
**Subtitle:** Beautiful native playback for your server
**Category:** Photo & Video (secondary: Entertainment)
**Price:** Free (add a one-time "Pro" unlock later via IAP if desired)

**Description (draft):**

> Connect to your own Plex or Jellyfin server — or a plain SMB share — and
> watch your library with hardware-decoded 4K HDR playback, Dolby Vision
> tone mapping, and gorgeous artwork-first browsing.
>
> • Direct play everything mpv can decode — no server transcoding
> • 4K HDR / Dolby Vision with dynamic tone mapping
> • Plex and Jellyfin accounts, user profiles and watch-state sync
> • Continue Watching, skip-intro markers, seek-preview thumbnails
> • Offline downloads with resume that carries over
> • Rotten Tomatoes and community ratings on your library
> • External subtitles (including OpenSubtitles agent downloads), styling,
>   sync and language preferences
> • Client-side upscaling with adaptive sharpening
>
> MediaPlayer is an open-source client. It streams only from servers you
> connect; it hosts no content of its own.

**Keywords:** plex,jellyfin,media player,mpv,4k,hdr,dolby vision,smb,nas,video

## Privacy label

"Data Not Collected" — the app talks only to the user's own server, plex.tv
(sign-in), TMDB (artwork, user-supplied key), and nothing else. No analytics,
no third-party SDKs, no accounts of our own.

## Review notes (template — fill server address before submitting)

> This app is a client for the user's own media server; reviewers need a
> server to test against (the most common rejection for this category, so
> provided here):
>
> Demo Plex server: https://DEMO-SERVER-ADDRESS:32400
> Demo account: DEMO-EMAIL / DEMO-PASSWORD  (non-VIP test account,
> pre-loaded with public-domain films)
>
> Sign in with Plex on first launch, pick the demo user, and the library
> loads. Playback, downloads and settings need no further setup.
>
> The app plays only content from servers the user connects. It does not
> host, index or link to any content source of its own.

Practical notes for the demo server: a $5/mo VPS running Plex or Jellyfin
with a handful of public-domain films (Night of the Living Dead, Charade,
His Girl Friday — all verifiably PD) avoids both content questions and
exposing the home server.

## Licensing position (already done in-repo)

- App links MPVKit's **LGPL** product (not GPL) — commit history has the swap.
- mediacore and the apps are MPL-2.0; MPL is App Store-compatible.
- Ship LGPL license texts with the binary: add MPVKit's THIRD-PARTY notices
  to a "Licenses" screen or bundle folder before submission.
- TMDB key is user-supplied (Settings → Files), keeping TMDB's
  non-commercial terms the user's obligation.

## Checklist to submit

- [ ] Apple Developer Program membership active
- [ ] `DEVELOPMENT_TEAM` set in `apps/ios/project.yml`, `CODE_SIGNING_ALLOWED`
      flipped to YES (device + archive builds)
- [ ] App icons: 1024pt marketing icon exists (`AppIcon-1024.png`); verify
      all slot sizes render in Xcode
- [ ] Screenshots: 6.9" iPhone, 13" iPad, Apple TV, Mac (docs/*.jpg are a
      good starting set for Mac)
- [ ] Demo server up + credentials in review notes
- [ ] LGPL notices screen
- [ ] Export compliance: uses HTTPS only → "standard encryption, exempt"
