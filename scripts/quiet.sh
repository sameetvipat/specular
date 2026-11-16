#!/usr/bin/env bash
# Quiet build wrapper. Usage: scripts/quiet.sh <build-script> [args...]
# Sends all build output to build/logs/<script>.log.
#   success -> prints "OK <script>"
#   failure -> prints "FAILED <script>", up to 30 error lines, then the log path.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -ge 1 ] || { echo "usage: scripts/quiet.sh <build-script> [args...]"; exit 2; }
arg="$1"; shift
name="$(basename "$arg")"
script="$arg"; [ -f "$script" ] || script="$ROOT/scripts/$name"
mkdir -p "$ROOT/build/logs"
log="$ROOT/build/logs/${name%.sh}.log"
if bash "$script" "$@" >"$log" 2>&1; then
  echo "OK $name"
else
  echo "FAILED $name"
  grep -nE "error:|fatal|undefined" "$log" | head -30
  echo "log: $log"
  exit 1
fi
