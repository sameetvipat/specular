#!/usr/bin/env bash
# One repeatable check: build, make small test clips, run the player's scripted tests
# (app/SelfTest.swift). Exits non-zero if anything fails. Opens the player window briefly.
#   scripts/selftest.sh [workdir]        (default: a fresh temp dir)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
W="${1:-$(mktemp -d)}"; mkdir -p "$W"
FF=/opt/homebrew/bin/ffmpeg
P=.build/debug/player
REF=~/Developer/specular-refs/HeartOfTheBeast_a_1114.mp4   # Dolby Vision Profile 8.1 + HDR10+
fail=0
check() {   # check <name> <text> <pattern that must match> [pattern that must not match]
  if echo "$2" | grep -qE "$3" && { [ -z "${4:-}" ] || ! echo "$2" | grep -qE "$4"; }; then echo "PASS  $1"
  else echo "FAIL  $1"; echo "$2" | grep -E 'TEST|PLAYFOR|playing|fail' | sed 's/^/      /'; fail=1; fi
}
passes() { echo "$1" | grep -c 'TEST.* PASS'; }

scripts/quiet.sh build.sh || exit 1

# Clip: video + stereo AAC (default track) + 5.1 E-AC-3.
$FF -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=640x360:r=24:d=20 \
  -f lavfi -i sine=f=440:d=20 -f lavfi -i sine=f=880:d=20 \
  -filter_complex "[1:a]pan=stereo|FL=c0|FR=c0[s];[2:a]pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0[m]" \
  -map 0:v -map "[s]" -map "[m]" -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -c:a:0 aac -c:a:1 eac3 -disposition:a:0 default -disposition:a:1 0 "$W/two.mkv" || { echo "FAIL  make clip"; exit 1; }

out=$(PLAYER_SELFTEST=1 $P "$W/two.mkv" 2>&1)
check "local file: play, seek, audio switch" "$out" 'TEST audio switch PASS' 'TEST.* FAIL'
[ "$(passes "$out")" = 3 ] || { echo "FAIL  local file: not 3/3 PASS"; fail=1; }

out=$(PLAYER_SELFTEST=1 PLAYER_INFOTEST="$W/two.mkv" $P 2>&1)
check "library media info (tags, codecs)"  "$out" 'INFOTEST PASS SD \| H\.264 \| SDR \| .*AAC Stereo.*Dolby Digital Plus 5\.1'

out=$(PLAYER_SELFTEST=1 PLAYER_AUDIOID=2 PLAYER_PLAYFOR=3 $P "$W/two.mkv" 2>&1)
check "audio track chosen before Play"      "$out" 'audio "Dolby Digital Plus 5.1" of 2'

out=$(PLAYER_SELFTEST=1 PLAYER_PANELTEST=1 PLAYER_PLAYFOR=30 $P "$W/two.mkv" 2>&1)
check "app stays open after choosing a file" "$out" 'PANELTEST alive: PASS'

out=$(PLAYER_SLOWOPEN=1 PLAYER_SELFTEST=1 PLAYER_PLAYFOR=2 $P "$W/two.mkv" 2>&1 | tr '\n' ' ')
check "loading screen on a slow open"        "$out" 'LOADING shown.*playing'

# Audio-only file (no video stream)
$FF -hide_banner -loglevel error -y -f lavfi -i sine=f=440:d=20 -c:a flac "$W/audio.flac"
out=$(PLAYER_SELFTEST=1 $P "$W/audio.flac" 2>&1)
check "audio-only file: play, seek"          "$out" 'TEST seek.* PASS' 'TEST.* FAIL'

# Network stream: local HTTP server with Range support
python3 -I tools/net/rangeserver.py "$W" 18741 0 & srv1=$!
trap 'kill $srv1 2>/dev/null' EXIT
sleep 1
out=$(PLAYER_SELFTEST=1 $P "http://127.0.0.1:18741/two.mkv" 2>&1)
check "network stream: play, seek"           "$out" 'TEST seek.* PASS' 'TEST.* FAIL'

# Dolby Vision label: a P8.1 file that also carries HDR10+ must say Dolby Vision (Aether says hdr10Plus)
if [ -f "$REF" ]; then
  out=$(PLAYER_SELFTEST=1 $P "$REF" 2>&1)
  check "Dolby Vision label (Profile 8.1)"   "$out" 'TEST label DOLBY VISION · P8'
else echo "SKIP  Dolby Vision label ($REF missing)"; fi

# Library: file-name parser, local .nfo / artwork / id tags, folder scan (no window, no network)
rm -rf "$W/lib"; mkdir -p "$W/lib/Films" "$W/lib/My Show/Season 1"
touch "$W/lib/Films/Some.Film.2020.1080p.mkv" "$W/lib/My Show/Season 1/S01E01.mkv" "$W/lib/My Show/Season 1/S01E02.mkv" "$W/lib/Films/notes.txt"
# disc folders and an .iso count as one film each; the clips inside a disc never show
mkdir -p "$W/lib/Films/Disc.Film.2010/BDMV/STREAM" "$W/lib/Films/Old DVD (1999)/VIDEO_TS"
touch "$W/lib/Films/Disc.Film.2010/BDMV/STREAM/00000.m2ts" "$W/lib/Films/Old DVD (1999)/VIDEO_TS/VTS_01_1.VOB" "$W/lib/Films/Image (2005).iso"
out=$(PLAYER_SELFTEST=1 PLAYER_LIBTEST="$W/lib" $P 2>&1)
check "library parser, local metadata, scan" "$out" 'scan: 6 films, 1 shows, 2 episodes' 'LIBTEST (parse|local|logos) FAIL'

.build/debug/mkcc "$W/cc.mkv" h264 >/dev/null 2>&1
out=$(PLAYER_SELFTEST=1 PLAYER_PLAYFOR=2 $P "$W/cc.mkv" 2>&1)
check "closed captions listed as a subtitle track" "$out" 'subtitles -?[0-9]+ of [1-9]'

printf '1\n00:00:00,500 --> 00:00:09,000\nAdded subtitle file\n' > "$W/added.srt"
out=$(PLAYER_SELFTEST=1 PLAYER_PLAYFOR=3 PLAYER_SUBFILE="$W/added.srt" $P "$W/two.mkv" 2>&1)
check "add subtitle file (.srt)"             "$out" 'PLAYFOR cues [1-9].*Added subtitle file'

out=$(PLAYER_SELFTEST=1 PLAYER_SNAPTEST=1 $P "$W/two.mkv" 2>&1)
check "save frame (PNG)"                     "$out" 'SNAPTEST PASS .*\.png [0-9]+'

out=$(PLAYER_SELFTEST=1 PLAYER_UNITTEST=1 $P 2>&1)
check "HDR routing table, hot keys"          "$out" 'UNITTEST PASS route' 'UNITTEST FAIL'

out=$(PLAYER_JELLYTEST=1 $P 2>&1)
check "jellyfin: reply parsing, stream URL"  "$out" 'JELLYTEST PASS' 'JELLYTEST FAIL'

out=$(PLAYER_SELFTEST=1 PLAYER_SETTINGTEST=1 PLAYER_PLAYFOR=6 $P "$W/two.mkv" 2>&1)
check "settings apply live (no reopen)"      "$out" 'engine shaping compressor.*applied' 'reopening'

[ $fail = 0 ] && echo "ALL PASS" || { echo "SOME FAILED (clips in $W)"; exit 1; }
