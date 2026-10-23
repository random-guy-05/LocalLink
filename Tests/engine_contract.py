"""Validate real profile options with Moonlight's parser, without starting a stream."""
import json
import subprocess
import sys
from pathlib import Path

engine = Path('/Applications/Moonlight.app/Contents/MacOS/Moonlight')
if not engine.exists():
    engine = Path.home() / 'Applications/Moonlight.app/Contents/MacOS/Moonlight'
if not engine.exists():
    raise SystemExit('Moonlight is required for the engine integration check.')
for profile in ['smooth', 'sharp', 'travel']:
    arguments = json.loads(subprocess.check_output([sys.argv[1], '--print-arguments', profile], text=True))
    result = subprocess.run([str(engine), *arguments, '--help'], capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        raise SystemExit(profile + ': ' + result.stdout + result.stderr)
    print('PASS: installed Moonlight accepts the complete ' + profile + ' profile.')
