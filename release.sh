#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_version="0.5.2"
task_dmgbuild="${DMGBUILD:-dmgbuild}"
task_app="$task_root/dist/LocalLink.app"
[[ -d "$task_app" ]] || { echo "Run build.sh first." >&2; exit 1; }
mkdir -p "$task_root/build" "$task_root/dist"
/usr/bin/codesign --verify --deep --strict "$task_app"
/usr/bin/lipo "$task_app/Contents/MacOS/LocalLink" -verify_arch x86_64 arm64
/usr/bin/swift "$task_root/Tools/DmgBackground.swift" "$task_root/build/dmg-background.png"
"$task_dmgbuild" -s "$task_root/Tools/dmg-settings.py" \
  -D "app=$task_app" -D "guide=$task_root/Resources/Start Here.html" \
  -D "background=$task_root/build/dmg-background.png" \
  "LocalLink $task_version" "$task_root/dist/LocalLink-$task_version-universal.dmg"
/usr/bin/hdiutil verify "$task_root/dist/LocalLink-$task_version-universal.dmg"
(cd "$task_root/dist" && /usr/bin/shasum -a 256 "LocalLink-$task_version-universal.dmg" > SHA256SUMS.txt)
echo "DMG and checksum are ready in dist/."
