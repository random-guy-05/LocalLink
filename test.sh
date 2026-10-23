#!/bin/bash
set -euo pipefail
task_source="$(cd "$(dirname "$0")" && pwd)"
task_scratch="$task_source/build/tests"
mkdir -p "$task_scratch"
/usr/bin/xcrun swiftc "$task_source/Native/Transport.swift" "$task_source/Tests/NativeTransport.swift" \
  -parse-as-library -o "$task_scratch/native-transport"
"$task_scratch/native-transport"
if [[ "${LOCALLINK_SKIP_HARDWARE_TEST:-0}" != "1" ]]; then
  /usr/bin/xcrun swiftc "$task_source/Native/Transport.swift" "$task_source/Native/Video.swift" \
    "$task_source/Native/Audio.swift" "$task_source/Tests/NativeVideo.swift" \
    -parse-as-library -o "$task_scratch/native-video"
  "$task_scratch/native-video"
fi
