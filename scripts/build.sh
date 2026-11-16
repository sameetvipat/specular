#!/usr/bin/env bash
# Build with SwiftPM (debug). No argument: every product. With an argument: that product only.
#   scripts/quiet.sh build.sh            # player, sckcap, probe, frameprobe, mkcc
#   scripts/quiet.sh build.sh probe      # -> .build/debug/probe
# Release app: scripts/quiet.sh make_app.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# Built-in TMDB key: gitignored, so a fresh clone has none. An empty one builds (keyless sources).
[ -f app/TMDBKey.swift ] || printf '// Built-in API keys. Gitignored: never commit a real key.\nlet builtInTMDBKey = ""\nlet builtInOMDbKey = ""\n' > app/TMDBKey.swift
if [ $# -ge 1 ]; then swift build --product "$1"; else swift build; fi
