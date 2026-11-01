#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh "${1:-debug}"
state_dir="$(mktemp -d "$PWD/artifacts/ui-XXXXXX")"
printf 'UI test artifacts: %s\n' "$state_dir"
MACFILE_TEST_EXIT=1 MACFILE_STATE_DIR="$state_dir" \
  ./artifacts/Macfile.app/Contents/MacOS/Macfile --ui-test
