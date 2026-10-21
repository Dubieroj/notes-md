#!/bin/bash
# Собирает «Notes MD.app» («Заметки.md») в папке build/ и запускает его. Можно передать файл: ./run.sh заметка.md
# С Xcode и xcodegen собирается полное приложение с расширениями (виджеты, «Поделиться»,
# Quick Look, «Команды»); без xcodegen или с PERO_SPM=1 — только приложение через SwiftPM.
set -e
cd "$(dirname "$0")"

# Страница редактора (CodeMirror). Готовая сборка лежит в Resources/web, поэтому Node нужен только для правок в web/.
if command -v npm >/dev/null; then
  [ -d web/node_modules ] || npm --prefix web ci --silent
  (cd web && node build.mjs)
elif [ ! -f Resources/web/js/main.js ]; then
  echo "Нужен Node.js (brew install node), чтобы собрать web/." >&2
  exit 1
fi

APP="build/Notes MD.app"
DERIVED=.xcbuild
# Сборка для автопроверок (tools/check*.sh): с тестовым пультом и отдельно от обычной.
if [ "${PERO_TEST_HOOKS:-0}" = 1 ]; then
  APP="build/test/Notes MD.app"
  DERIVED=.xcbuild-test
fi
pkill -f "$PWD/$APP/Contents/MacOS/Pero" || true  # only the copy built here, never the installed app

# Команда разработчика для подписи: PERO_TEAM или та, что в сертификате Apple Development.
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
  # Подпись сертификатом разработчика, если он есть; иначе ad-hoc.
  IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
  codesign --force --sign "${IDENTITY:--}" "$APP"
fi

# Сборка без запуска не регистрируется в macOS: для .md система берёт приложение из «Программ», а не копию отсюда.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ "$NO_OPEN" = 1 ]; then
  for copy in "$PWD/$DERIVED/Build/Products/Release/Pero.app" "$PWD/$APP"; do "$LSR" -u "$copy" 2>/dev/null || true; done
fi
[ "$NO_OPEN" = 1 ] || open -a "$PWD/$APP" "$@"
