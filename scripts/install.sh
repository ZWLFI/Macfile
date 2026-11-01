#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh release
install_root="${MACFILE_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$install_root"
if [ -e "$install_root/Macfile.app" ]; then
  previous="$install_root/Macfile-backup-$(date +%Y%m%d-%H%M%S).app"
  mv "$install_root/Macfile.app" "$previous"
fi
ditto artifacts/Macfile.app "$install_root/Macfile.app"
codesign --verify --deep --strict "$install_root/Macfile.app"
open "$install_root/Macfile.app"
printf 'Installed: %s\n' "$install_root/Macfile.app"
