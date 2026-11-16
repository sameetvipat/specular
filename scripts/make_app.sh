#!/usr/bin/env bash
# Build a double-clickable, self-contained build/Specular.app from the SwiftPM executable:
# release `player` + AetherEngine's FFmpeg frameworks + SwiftPM resource bundles, ad-hoc signed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The shipped app must carry the TMDB key (app/TMDBKey.swift, gitignored): no key, no release build.
grep -qE 'builtInTMDBKey *= *"[^"[:space:]]{16,}"' app/TMDBKey.swift 2>/dev/null \
  || { echo "error: app/TMDBKey.swift has no TMDB key; put it in: let builtInTMDBKey = \"…\""; exit 1; }
grep -qE 'builtInOMDbKey *= *"[^"[:space:]]{8,}"' app/TMDBKey.swift 2>/dev/null \
  || { echo "error: app/TMDBKey.swift has no OMDb key; put it in: let builtInOMDbKey = \"…\""; exit 1; }
echo "==> release build"
swift build -c release --product player
BIN="$ROOT/.build/release"

APP="$ROOT/build/Specular.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/player" "$APP/Contents/MacOS/Specular"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>Specular</string>
  <key>CFBundleDisplayName</key>        <string>Specular</string>
  <key>CFBundleIdentifier</key>         <string>local.sameet.specular</string>
  <key>CFBundleExecutable</key>         <string>Specular</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1</string>
  <key>CFBundleVersion</key>            <string>1</string>
  <key>LSMinimumSystemVersion</key>     <string>26.0</string>
  <key>NSHighResolutionCapable</key>    <true/>
  <key>NSPrincipalClass</key>           <string>NSApplication</string>
  <key>NSAppTransportSecurity</key>     <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>   <string>Video</string>
      <key>CFBundleTypeRole</key>   <string>Viewer</string>
      <key>LSHandlerRank</key>      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.audiovisual-content</string>
        <string>public.audio</string>
        <string>public.mpeg-4</string>
        <string>com.apple.quicktime-movie</string>
        <string>org.matroska.mkv</string>
        <string>public.mpeg-2-transport-stream</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

EXE="$APP/Contents/MacOS/Specular"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"

# @rpath framework names a Mach-O file links against (AetherEngine's FFmpeg frameworks).
rpath_fws() { otool -L "$1" | awk '$1 ~ /^@rpath\/.*\.framework\// { split($1, p, "/"); print p[2] }' | sort -u; }

echo "==> embed frameworks (SwiftPM does not; follow framework-to-framework links too)"
todo="$(rpath_fws "$EXE")"
while [ -n "$todo" ]; do
  next=""
  for fw in $todo; do
    [ -d "$FW/$fw" ] && continue
    [ -d "$BIN/$fw" ] || { echo "error: $fw not found in $BIN"; exit 1; }
    cp -R "$BIN/$fw" "$FW/"
    chmod -R u+w "$FW/$fw"   # SwiftPM's copies are read-only; codesign must rewrite them
    next="$next $(rpath_fws "$FW/$fw/${fw%.framework}")"
  done
  todo="$next"
done
echo "embedded $(ls "$FW" | wc -l | tr -d ' ') frameworks"

echo "==> resource bundles (Bundle.module looks in Contents/Resources)"
for b in "$BIN"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

echo "==> rpath: only the app's own Frameworks folder"
otool -l "$EXE" | awk '/LC_RPATH/ { r = 1 } r && $1 == "path" { print $2; r = 0 }' | while read -r rp; do
  install_name_tool -delete_rpath "$rp" "$EXE"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"

echo "==> self-contained check"
bad="$(for f in "$EXE" "$FW"/*.framework; do
  [ -d "$f" ] && f="$f/$(basename "$f" .framework)"
  otool -L "$f" | awk '/^\t/ {print $1}' | grep -E '^(/opt/homebrew|/usr/local|/Users)' || true
  for fw in $(rpath_fws "$f"); do [ -d "$FW/$fw" ] || echo "missing $fw"; done
done)"
[ -z "$bad" ] || { echo "error: not self-contained:"; echo "$bad"; exit 1; }
echo "no Homebrew/local refs, every @rpath framework embedded"

echo "==> ad-hoc sign (frameworks and resource bundles first, then the app)"
codesign --force --timestamp=none -s - "$FW"/*.framework "$APP"/Contents/Resources/*.bundle
codesign --force --timestamp=none -s - "$APP"
codesign --verify --deep --strict "$APP" && echo "signature ok (deep strict)"
echo "==> built $APP"
