#!/bin/bash
# Builds "Notes MD.app" (Notes.md) into build/ and launches it. A file can be passed: ./run.sh note.md
# With Xcode, xcodegen and a signing certificate the full app is built, with its extensions (widgets,
# Share, Quick Look, Shortcuts); otherwise, or with PERO_SPM=1, only the app itself, through SwiftPM.
set -e
cd "$(dirname "$0")"

# The editor page (CodeMirror). A built copy is kept in Resources/web, so Node is only needed to change web/.
if command -v npm >/dev/null; then
  [ -d web/node_modules ] || npm --prefix web ci --silent
  (cd web && node build.mjs)
elif [ ! -f Resources/web/js/main.js ]; then
  echo "Node.js is needed to build web/ (brew install node)." >&2
  exit 1
fi

APP="build/Notes MD.app"
DERIVED=.xcbuild
# The build for the app checks (tools/check*.sh): with the test control channel, apart from the regular one.
if [ "${PERO_TEST_HOOKS:-0}" = 1 ]; then
  APP="build/test/Notes MD.app"
  DERIVED=.xcbuild-test
fi
pkill -f "$PWD/$APP/Contents/MacOS/Pero" || true  # only the copy built here, never the installed app

# The development team for signing: PERO_TEAM, or the one in the Apple Development certificate.
TEAM="${PERO_TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')}"

if command -v xcodegen >/dev/null && [ "${PERO_SPM:-0}" != 1 ] && [ -n "$TEAM" ]; then
  xcodegen generate --quiet
  EXTRA=()
  [ "$DERIVED" = .xcbuild ] || EXTRA=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PERO_TEST_HOOKS')
  xcodebuild -project Pero.xcodeproj -scheme Pero -configuration Release -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates -quiet DEVELOPMENT_TEAM="$TEAM" ${PERO_BUNDLE_ID:+PERO_BUNDLE_ID="$PERO_BUNDLE_ID"} "${EXTRA[@]}" build
  rm -rf "$APP"
  mkdir -p "$(dirname "$APP")"
  ditto "$DERIVED/Build/Products/Release/Pero.app" "$APP"
else
  if [ "$DERIVED" = .xcbuild ]; then
    swift build -c release -q
    BIN=.build/release/Pero
  else
    swift build -c release -q --scratch-path .build/test -Xswiftc -DPERO_TEST_HOOKS
    BIN=.build/test/release/Pero
  fi
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/"
  cp Info.plist "$APP/Contents/"
  cp -R Resources/web Resources/AppIcon.icns Resources/ru.lproj Resources/en.lproj "$APP/Contents/Resources/"
  # Signed with the development certificate if there is one, ad hoc otherwise.
  IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
  codesign --force --sign "${IDENTITY:--}" "$APP"
fi

# A build that isn't launched is unregistered from macOS, so .md files open in the installed app, not in this copy.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ "$NO_OPEN" = 1 ]; then
  for copy in "$PWD/$DERIVED/Build/Products/Release/Pero.app" "$PWD/$APP"; do "$LSR" -u "$copy" 2>/dev/null || true; done
fi
[ "$NO_OPEN" = 1 ] || open -a "$PWD/$APP" "$@"
