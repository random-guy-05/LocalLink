#!/bin/bash
set -euo pipefail
task_source="$(cd "$(dirname "$0")" && pwd)"
task_scratch="$task_source/build/tests"
mkdir -p "$task_scratch"
/usr/bin/xcrun swiftc "$task_source/Core.swift" "$task_source/Runtime.swift" \
  "$task_source/Tests/Regression.swift" -parse-as-library -o "$task_scratch/locallink-regression"
"$task_scratch/locallink-regression"
if [[ "${LOCALLINK_SKIP_ENGINE_CHECK:-0}" != "1" ]]; then
  /usr/bin/python3 "$task_source/Tests/engine_contract.py" "$task_source/dist/LocalLink.app/Contents/MacOS/LocalLink"
fi
