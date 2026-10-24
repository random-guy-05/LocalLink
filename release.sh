#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_version="0.5.3"
task_dmgbuild="${DMGBUILD:-dmgbuild}"
task_variant="${LOCALLINK_VARIANT:-modern}"
case "$task_variant" in
  modern) task_minimum="14.0"; task_app="$task_root/dist/LocalLink.app"; task_suffix="universal" ;;
  legacy) task_minimum="12.3"; task_app="$task_root/dist/legacy/LocalLink.app"; task_suffix="legacy-macos12.3-universal" ;;
  *) echo "Unknown build variant: $task_variant" >&2; exit 1 ;;
esac
task_dmg="$task_root/dist/LocalLink-$task_version-$task_suffix.dmg"
[[ -d "$task_app" ]] || { echo "Run build.sh first." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$task_app/Contents/Info.plist")" == "$task_version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$task_app/Contents/Info.plist")" == "$task_minimum" ]]
mkdir -p "$task_root/build" "$task_root/dist"
/usr/bin/codesign --verify --deep --strict "$task_app"
/usr/bin/lipo "$task_app/Contents/MacOS/LocalLink" -verify_arch x86_64 arm64
/usr/bin/swift "$task_root/Tools/DmgBackground.swift" "$task_root/build/dmg-background-$task_variant.png"
"$task_dmgbuild" -s "$task_root/Tools/dmg-settings.py" \
  -D "app=$task_app" -D "guide=$task_root/Resources/Start Here.html" \
  -D "background=$task_root/build/dmg-background-$task_variant.png" \
  "LocalLink $task_version $task_variant" "$task_dmg"
/usr/bin/hdiutil verify "$task_dmg"
(cd "$task_root/dist" && /usr/bin/shasum -a 256 LocalLink-"$task_version"-*.dmg > SHA256SUMS.txt)
echo "DMG and checksum are ready in dist/."
