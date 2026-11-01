#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh release
install_root="${MACFILE_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$install_root"
staging="$(mktemp -d "$install_root/.Macfile-install-XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto artifacts/Macfile.app "$staging/Macfile.app"
codesign --verify --deep --strict "$staging/Macfile.app"
swift scripts/prepare-install.swift "$staging/Macfile.app" "$install_root/Macfile.app"
open "$install_root/Macfile.app"
printf 'Installed: %s\n' "$install_root/Macfile.app"
