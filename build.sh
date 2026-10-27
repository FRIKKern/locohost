#!/bin/sh
# Builds a universal LocoHost.app into ./build and installs it to ~/Applications.
# Usage: ./build.sh [--no-install]
set -e
cd "$(dirname "$0")"
APP=build/LocoHost.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=13.0 -arch arm64 -arch x86_64 \
  -framework Cocoa -framework ServiceManagement \
  Sources/main.m Sources/Ports.m Sources/Rules.m Sources/Review.m Sources/Intel.m -o "$APP/Contents/MacOS/LocoHost"
cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/LocoHost"))"
[ "$1" = "--no-install" ] && exit 0
mkdir -p ~/Applications ~/.local/bin
rm -rf ~/Applications/LocoHost.app
cp -R "$APP" ~/Applications/
ln -sf ~/Applications/LocoHost.app/Contents/MacOS/LocoHost ~/.local/bin/locohost
# URLs such as locohost://quit must reach the installed app, not the copy in ./build.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$PWD/$APP" >/dev/null 2>&1 || true
"$LSREG" -f ~/Applications/LocoHost.app >/dev/null 2>&1 || true
echo "Installed ~/Applications/LocoHost.app and ~/.local/bin/locohost"
