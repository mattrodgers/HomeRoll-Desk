#!/bin/bash
# Baut HomeRoll Desktop als ad hoc signierte App (keine Entwickler-Identität) und packt sie als zip.
# Ergebnis: build-app/HomeRoll-Desktop-<Version>.zip
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate -q
rm -rf build-app
xcodebuild -project HomeRollDesktop.xcodeproj -scheme HomeRollDesktop -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build-app \
  CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
  OTHER_SWIFT_FLAGS="-file-prefix-map $PWD=." OTHER_CFLAGS="-ffile-prefix-map=$PWD=." \
  STRIP_INSTALLED_PRODUCT=YES DEPLOYMENT_POSTPROCESSING=YES STRIP_STYLE=non-global -quiet build
APP="build-app/Build/Products/Release/HomeRoll Desktop.app"
[ -d "$APP" ] || { echo "FEHLER: $APP nicht gefunden"; exit 1; }
codesign -f -s - --deep "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Signature=adhoc" || { echo "FEHLER: nicht ad hoc signiert"; exit 1; }
# Keine Spuren des Bau-Rechners veröffentlichen (Baupfade enthalten sonst den Mac-Benutzernamen)
if grep -raqiF -e "$USER" -e "$HOME" "$APP"; then
  echo "FEHLER: Benutzername oder Home-Pfad in der App – aus einem neutralen Ordner bauen (z. B. git clone nach /tmp/build)."
  exit 1
fi
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ditto -c -k --keepParent "$APP" "build-app/HomeRoll-Desktop-$V.zip"
echo "Fertig: build-app/HomeRoll-Desktop-$V.zip"
