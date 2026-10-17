#!/bin/bash
# Builds build/Co-learner.app (release). Pass --install to also copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/make_library.py >/dev/null
swift build -c release 2>&1 | grep -v "search path .* not found" || true
test -x .build/release/CoLearner
APP=build/Co-learner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CoLearner "$APP/Contents/MacOS/Co-learner"
cp -R Sources/CoLearner/Web "$APP/Contents/Resources/Web"
cp Sources/CoLearner/library.json "$APP/Contents/Resources/library.json"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
VERSION=$(cat VERSION 2>/dev/null || echo 0.1)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Co-learner</string>
  <key>CFBundleIdentifier</key><string>com.yifeidai.colearner</string>
  <key>CFBundleName</key><string>Co-learner</string>
  <key>CFBundleDisplayName</key><string>Co-learner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "built $APP"
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Co-learner.app"
  cp -R "$APP" "$HOME/Applications/Co-learner.app"
  echo "installed ~/Applications/Co-learner.app"
fi
