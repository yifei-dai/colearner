#!/bin/bash
# Builds build/app.noindex/Co-learner.app (release). Pass --install to also copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/make_library.py >/dev/null
rm -f .build/release/CoLearner   # so a failed build can't package the previous binary
swift build -c release 2>&1 | { grep -v "search path .* not found" || true; }
test -x .build/release/CoLearner
# Spotlight skips folders named *.noindex, so only the installed copy shows up when you search for the app.
APP=build/app.noindex/Co-learner.app
rm -rf "build/Co-learner.app" "$APP"   # build/Co-learner.app: where builds before 2026-10-30 put it
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
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict>
</plist>
PLIST
# Sign with the local certificate when it exists: macOS then keeps the Desktop-folder permission across
# rebuilds (an ad-hoc signature is a new app to macOS every build, so it asks again).
# One-time setup: see "Signing" in README.md.
IDENTITY="Co-learner Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  if err=$(codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP" 2>&1); then
    echo "signed with \"$IDENTITY\""
  else
    printf 'signing with "%s" failed:\n%s\n' "$IDENTITY" "$err" >&2
    if ! err=$(codesign --force --deep --sign - "$APP" 2>&1); then printf 'ad-hoc signing failed too:\n%s\n' "$err" >&2; exit 1; fi
    echo "signed ad-hoc instead (macOS will ask for Desktop access again)" >&2
  fi
else
  if ! err=$(codesign --force --deep --sign - "$APP" 2>&1); then printf 'ad-hoc signing failed:\n%s\n' "$err" >&2; exit 1; fi
  echo "signed ad-hoc (no \"$IDENTITY\" certificate: macOS will ask for Desktop access after each rebuild)"
fi
codesign --verify --deep --strict "$APP"
echo "built $APP"
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Co-learner.app"
  cp -R "$APP" "$HOME/Applications/Co-learner.app"
  echo "installed ~/Applications/Co-learner.app"
fi
