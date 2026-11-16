# Specular

**A Mac video player that gets HDR right.** Open a file or a stream and it plays. An optional library keeps your films and shows in one window. No accounts, no servers.

- **HDR10, HDR10+, HLG, Dolby Vision.** Specular's own HDR renderer (about twice as bright as QuickTime on most Macs) or Apple's, your choice. Dolby Vision through Apple on XDR screens, for Profile 5 and 7 FEL, and whenever you pick Apple.
- **Atmos and heights.** E-AC-3 Atmos through Apple's decoder; TrueHD Atmos and DTS:X rendered with their heights. Audio delay and 0.5x to 2x speed.
- **Plays what you have.** MKV, MP4, MOV, TS, AVI and more. Hardware decode for H.264, HEVC, AV1 and ProRes; software for the rest.
- **Subtitles.** SRT, ASS/SSA, WebVTT, PGS, VobSub, DVB, closed captions. Sidecar files found automatically.
- **Library.** Point it at your folders: films, shows and disc folders with artwork, ratings (IMDb, Rotten Tomatoes, TMDB), collections, progress and watched marks. Jellyfin servers too, with progress sync.
- **Streams.** Open a URL (HTTP, HTTPS and more) with buffering on slow links. Audio-only files play too.
- **Comfortable to watch.** Skip Intro / Credits, Up Next, sleep timer, a quick audio + subtitle menu, per-film memory of your track choices, picture in picture, a "?" shortcut sheet.
- **Mac-native.** Chapters, resume, Open Recent, media keys, drag and drop, float on top, editable hot keys.

## Audio settings by setup

Settings > Audio. A Mac cannot send TrueHD or DTS-HD untouched over HDMI, so Specular decodes every track
and hands macOS plain multichannel sound. "Lossless" repacks TrueHD / DTS-HD as FLAC inside the app (bit
for bit, up to 7.1); "Atmos / DTS:X heights" renders TrueHD Atmos and DTS:X objects into a speaker layout
with height channels.

| Setup | Atmos / DTS:X heights | Lossless TrueHD / DTS-HD | Dialogue lift, Night mode, Level loudness, Volume boost | Outside Specular |
|---|---|---|---|---|
| MacBook speakers | 7.1.4 (default) | On | Off | — |
| AirPods Pro / Max / 3 or later | 7.1.4 | On | Off | Control Center > Sound > Spatial Audio: Head Tracked or Fixed |
| Other headphones (wired, non-Apple Bluetooth) | 7.1.4 | On | Off | Plain stereo mix, heights folded in |
| Mac > HDMI > AV receiver | Off | On | Off | Audio MIDI Setup > HDMI device > Configure Speakers: 7.1. Receiver upmixer (Dolby Surround / Neural:X) on for ceiling speakers |
| Soundbar or TV on eARC | Off | On | Off | As the receiver: 7.1 or 5.1 to match the soundbar |
| Old soundbar on plain ARC | Off | On | Off | Stereo only from a Mac; no setting changes that |
| AirPlay (HomePod, Sonos) | 7.1.4 | On | Off | Expect no heights |
| Late night | any | On | Night mode on | Heights lost while on |
| Hard-to-hear dialogue | any | On | Dialogue lift on | Heights lost while on |
| Very different volume between films | any | On | Level loudness on | Heights lost while on |

- **Lossless:** always on. Off (lossy 5.1 Dolby Digital Plus) is meant for old soundbars and does not help on a Mac.
- **Heights 7.1.4** for anything that goes through macOS spatial audio (speakers, AirPods). **Off** for HDMI: the
  receiver then gets the clean lossless 7.1 instead of a 12-channel render that does not fit into 8.
- **The four sound tools** need plain decoded audio, so any one of them drops the Atmos / DTS:X heights.
  Dialogue lift raises voices (+6 dB), Night mode evens out loud and quiet parts, Level loudness plays every
  film at the same level (−24 LUFS), Volume boost adds +3 to +12 dB with a limiter.
- Not yet tested: the Mac's 8-channel HDMI limit, stereo-only plain ARC, no heights over AirPlay.

## Video settings by setup

Settings > Video. **HDR Colors** picks who draws HDR: **Specular** (default) draws HDR10, HDR10+ and the HDR base
of Dolby Vision itself, about twice as bright as Apple on most Macs, and rolls highlights off smoothly above
what the screen can show. **Apple** gives the QuickTime look. **Dolby Vision** on uses Apple's Dolby Vision
processing where it applies; off plays the HDR10 base layer. Press **D** in the player to switch Dolby Vision
for the current film only. SDR and HLG always use Apple's path.

| Setup | HDR Colors | Dolby Vision | Outside Specular |
|---|---|---|---|
| MacBook Air, iMac, other non-XDR screens | Specular (default) | On | Displays: brightness high; HDR headroom shrinks as brightness goes up, the picture still gains |
| MacBook Pro 14 / 16 (XDR), Pro Display XDR | Specular | On (Dolby Vision files then use Apple's real Dolby Vision) | — |
| Same XDR screens, reference look wanted | Apple | On | — |
| External HDR monitor or TV | Apple (untested with Specular) | On | Displays > that screen: High Dynamic Range on |
| External SDR monitor | Specular or Apple (both tone-map to SDR; untested) | On | — |
| Dolby Vision file looks wrong (green / purple tint, too dark) | any | Press **D** for this film | — |
| Dark room, several screens | any | On | Settings > Playback > Full screen: **Black out other displays** on |
| On battery | any | any | System Settings > Battery > Options: "Optimize video streaming while on battery" off, or HDR may play as SDR |

- **Always Apple, whatever the settings:** Dolby Vision Profile 5 (needs Dolby's own colour reshaping), Profile 7
  FEL (dual layer), Dolby Vision on XDR screens while Dolby Vision is on, SDR and HLG.
- **Specular on a Dolby Vision file** draws its HDR10 base: bright and stable, without Dolby's per-scene
  metadata. If a Dolby Vision film looks better with Apple on your screen, keep Apple for it.
- **On an HDR TV** (Mac over HDMI) the headroom is fixed: macOS derives it from what the TV reports, there is no
  slider. The TV then tone-maps the signal itself, so Specular's roll-off on top can dull highlights (double
  tone mapping): use HDR Colors = Apple there. The picture is mostly set on the TV: Filmmaker / Cinema mode,
  HGIG or dynamic tone mapping off, peak brightness high. macOS sends HDR10 over HDMI, not Dolby Vision.
- **Brightness on a Mac screen** trades overall brightness for highlight room: higher brightness lowers the
  headroom (brighter picture, squeezed highlights), lower brightness raises it (dimmer, more highlight pop).
  The peak stays the panel's maximum. Stats for Nerds > Screen shows the current and maximum headroom.
- Not yet tested: Specular on external HDR and SDR screens and TVs, the battery option's effect on Specular.

## Install

Requires an Apple Silicon Mac on macOS 26 and Swift 6.4 / Xcode 27. No prebuilt releases yet; build from source:

```sh
git clone https://github.com/sameetvipat/specular.git && cd specular
scripts/make_app.sh        # -> build/Specular.app
```

## Development

One SwiftPM package: `app/` (SwiftUI / AppKit), `tools/` (diagnostics), `scripts/`. Playback is [AetherEngine](https://github.com/superuser404notfound/AetherEngine) (demux, decode, HDR / Dolby Vision, audio, subtitle decode); styled ASS subtitles use libass through swift-ass-renderer.

```sh
scripts/build.sh [product]   # -> .build/debug/
```

The C diagnostic tools (`probe`, `frameprobe`, `mkcc`) need Homebrew FFmpeg (`brew install ffmpeg`); the app does not.

### Checks

```sh
scripts/selftest.sh          # build, make test clips, run playback / library / caption checks
```

Useful switches (environment variables):

| Switch | Effect |
|---|---|
| `PLAYER_SELFTEST=1` | Scripted play, seek, audio-track switch and HDR label check, then quit |
| `PLAYER_PLAYFOR=<sec>` | With the above: just play for that long, then print position and tracks |
| `PLAYER_START=<sec>` | Start position |
| `PLAYER_LIBTEST=<dir>` | Library parser and folder scan, no window |
| `PLAYER_METATEST=<file>` | Frame-grab cover and online metadata lookups (needs network) |
| `PLAYER_DEBUG=1` | Full-screen transition log |

The rest are in `app/SelfTest.swift`.

## Licences

Specular is AGPL-3.0. AetherEngine and its FFmpeg build are LGPL-3.0, linked dynamically (the
frameworks sit unmodified in `Specular.app/Contents/Frameworks`); swift-ass-renderer is MIT and libass is
ISC. The TrueHD / DTS:X object-audio and Dolby Vision components are turned on for this personal build and
may carry Dolby / DTS patent obligations for anyone who distributes it.

Brand logos (Dolby, DTS, HDR10 / HDR10+, IMDb, Rotten Tomatoes, TMDB) are trademarks of their owners. They are
not in this repository and not covered by the AGPL; a build without them shows text badges (see `app/Logos/README.md`).

Metadata: this product uses the TMDB API but is not endorsed or certified by TMDB. Ratings come from OMDb
(CC BY-NC 4.0, non-commercial use). Show data from TVmaze is CC BY-SA 4.0.

---

© 2026 Sameet Vipat. Licensed under the [GNU AGPL v3](LICENSE).
