#!/bin/bash
# Builds build/app.noindex/Co-learner.app (release). Pass --install to also copy it to ~/Applications.
# --install won't replace a copy built from newer code (say, a zip of an older tag over a newer build): add --force.
set -euo pipefail
cd "$(dirname "$0")/.."
INSTALL=0 FORCE=0
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    --force) FORCE=1 ;;
    *) echo "usage: scripts/build_app.sh [--install [--force]]" >&2; exit 2 ;;
  esac
done

# Which code this is (commit, commit time, date): from git in a clone, else from scripts/source-stamp.txt, which
# GitHub's zip downloads fill in (export-subst in .gitattributes). Info.plist keeps it and About Co-learner shows it,
# since small changes keep the version number.
c="" t="" d=""
if [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(pwd -P)" ]; then
  read -r c t d < <(git log -1 --format='%h %ct %cs' 2>/dev/null) || true
  git diff --quiet HEAD -- 2>/dev/null || c="$c+"   # + : with changes that aren't committed
else
  read -r c t d < <(grep -v '^#' scripts/source-stamp.txt 2>/dev/null) || true
fi
if [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -gt 0 ]; then
  SRC_COMMIT=$c SRC_TIME=$t SRC_DATE=$d SOURCE="$c, $d"
else   # a copy without git or a filled-in stamp (in a clone the stamp file still says $Format…$)
  SRC_COMMIT=unknown SRC_TIME=0 SRC_DATE="" SOURCE="a copy that doesn't say which commit it is"
fi

# Before building, so a refused install costs nothing.
DEST="$HOME/Applications/Co-learner.app"
if [ "$INSTALL" = 1 ] && [ "$FORCE" = 0 ] && [ -f "$DEST/Contents/Info.plist" ]; then
  installed() { /usr/libexec/PlistBuddy -c "Print :$1" "$DEST/Contents/Info.plist" 2>/dev/null || true; }
  OLD_TIME=$(installed CoLearnerSourceTime)
  [[ "$OLD_TIME" =~ ^[0-9]+$ ]] || OLD_TIME=0   # built before builds were stamped: can't tell, so replace it
  if [ "$OLD_TIME" -gt "$SRC_TIME" ]; then
    {
      echo "Not installed: ~/Applications/Co-learner.app is newer code ($(installed CoLearnerSourceCommit), $(installed CoLearnerSourceDate)) than this folder ($SOURCE)."
      echo "For the newest code: git clone https://github.com/yifei-dai/colearner.git (or git pull in your clone)."
      echo "To replace it anyway: scripts/build_app.sh --install --force"
    } >&2
    exit 1
  fi
fi

python3 tools/make_library.py >/dev/null
# A personal library (course folders, deck titles, study pages) is written outside the repo, to
# ~/Library/Application Support/Co-learner/library.json, by an optional git-ignored script; the app reads it first.
if [ -f tools/make_library.local.py ]; then python3 tools/make_library.local.py >/dev/null; fi
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
  <key>CoLearnerSourceCommit</key><string>${SRC_COMMIT}</string>
  <key>CoLearnerSourceTime</key><integer>${SRC_TIME}</integer>
  <key>CoLearnerSourceDate</key><string>${SRC_DATE}</string>
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
# One-time setup: see "Signing" in docs/USER_GUIDE.md.
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
if [ "$INSTALL" = 1 ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "installed ~/Applications/Co-learner.app ($VERSION, $SOURCE)"
fi
