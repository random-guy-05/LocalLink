#!/bin/bash
set -euo pipefail
task_source="$(cd "$(dirname "$0")/.." && pwd)"
task_scratch="$task_source/build/tests"
task_flags=(-target "$(uname -m)-apple-macosx14.0")
if [[ "${LOCALLINK_VARIANT:-modern}" == "legacy" ]]; then
  task_scratch="$task_source/build/tests-legacy"
  task_flags=(-target "$(uname -m)-apple-macosx12.3" -D LOCALLINK_LEGACY)
fi
mkdir -p "$task_scratch"
/usr/bin/xcrun swiftc "${task_flags[@]}" "$task_source/Sources/Transport.swift" "$task_source/Tests/NativeTransport.swift" \
  -parse-as-library -o "$task_scratch/native-transport"
"$task_scratch/native-transport"
if [[ "${LOCALLINK_SKIP_HARDWARE_TEST:-0}" != "1" ]]; then
  /usr/bin/xcrun swiftc "${task_flags[@]}" "$task_source/Sources/Transport.swift" "$task_source/Sources/Experience.swift" "$task_source/Sources/Video.swift" \
    "$task_source/Sources/Audio.swift" "$task_source/Tests/NativeVideo.swift" \
    -parse-as-library -o "$task_scratch/native-video"
  "$task_scratch/native-video"
fi

/usr/bin/xcrun swiftc "${task_flags[@]}" "$task_source/Sources/Transport.swift" "$task_source/Sources/Experience.swift" \
  "$task_source/Sources/Model.swift" "$task_source/Sources/Permissions.swift" "$task_source/Sources/Control.swift" \
  "$task_source/Sources/Video.swift" "$task_source/Sources/Audio.swift" "$task_source/Tests/SessionRegression.swift" \
  -parse-as-library -o "$task_scratch/native-session"
"$task_scratch/native-session"
