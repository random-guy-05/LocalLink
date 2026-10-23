#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_version="0.4.1"
task_arches="${LOCALLINK_ARCHS:-$(uname -m)}"
task_app="$task_root/dist/LocalLink.app"
task_build="$task_root/build"
mkdir -p "$task_build" "$task_root/dist"
rm -rf "$task_app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
task_slices=()
for task_arch in $task_arches; do
  case "$task_arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $task_arch" >&2; exit 1 ;; esac
  task_binary="$task_build/LocalLink-$task_arch"
  /usr/bin/xcrun swiftc "$task_root"/Native/*.swift -parse-as-library -O -module-name LocalLink \
    -file-prefix-map "$task_root=/LocalLink" -debug-prefix-map "$task_root=/LocalLink" \
    -target "$task_arch-apple-macosx14.0" -o "$task_binary"
  task_slices+=("$task_binary")
done
/usr/bin/lipo -create "${task_slices[@]}" -output "$task_app/Contents/MacOS/LocalLink"
cat > "$task_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalLink</string>
<key>CFBundleIdentifier</key><string>local.locallink.viewer</string>
<key>CFBundleName</key><string>LocalLink</string>
<key>CFBundleDisplayName</key><string>LocalLink</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$task_version</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundleIconFile</key><string>LocalLink</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Share this Mac’s screen and system sound with your paired LocalLink viewer.</string>
<key>NSLocalNetworkUsageDescription</key><string>Connect directly to your other Mac for encrypted screen, sound, and input streaming.</string>
</dict></plist>
PLIST
cp "$task_root/Resources/Start Here.html" "$task_app/Contents/Resources/"
task_icons="$task_build/LocalLink.iconset"
mkdir -p "$task_icons" "$task_root/assets"
/usr/bin/swift "$task_root/Tools/Icon.swift" "$task_build/icon.png"
cp "$task_build/icon.png" "$task_root/assets/icon.png"
for task_size in 16 32 128 256 512; do
  /usr/bin/sips -z "$task_size" "$task_size" "$task_build/icon.png" --out "$task_icons/icon_${task_size}x${task_size}.png" >/dev/null
  task_double=$((task_size * 2))
  /usr/bin/sips -z "$task_double" "$task_double" "$task_build/icon.png" --out "$task_icons/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$task_icons" -o "$task_app/Contents/Resources/LocalLink.icns"
/usr/bin/codesign --force --sign - "$task_app"
/usr/bin/codesign --verify --deep --strict "$task_app"
/usr/bin/lipo -info "$task_app/Contents/MacOS/LocalLink"
echo "Built LocalLink $task_version at $task_app"
