#!/bin/sh
# Builds SystemEQ.app into build/.
#
#   scripts/build-app.sh            build and sign
#   scripts/build-app.sh --install  also copy to /Applications and launch it
#
# Signs with the first "Developer ID Application" identity in the keychain (override
# with SIGN_IDENTITY). A stable signature means macOS remembers the audio capture
# permission across rebuilds; ad-hoc signing (the fallback) asks again after each build.
set -e
cd "$(dirname "$0")/.."

APP=build/SystemEQ.app

swift build -c release
BIN="$(swift build -c release --show-bin-path)/SystemEQ"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SystemEQ"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc signature})"

if [ "$1" = "--install" ]; then
  pkill -x SystemEQ 2>/dev/null || true
  rm -rf /Applications/SystemEQ.app
  cp -R "$APP" /Applications/
  open /Applications/SystemEQ.app
  echo "Installed to /Applications/SystemEQ.app"
fi
