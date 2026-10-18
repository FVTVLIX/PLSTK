#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FVTVLIX and PLSTK contributors.

set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app="$PWD/Build/PLSTK.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "${binary_dir}/PLSTK" "$app/Contents/MacOS/PLSTK"
cp scripts/Info.plist "$app/Contents/Info.plist"
cp LICENSE COPYRIGHT THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
codesign --force --sign - "$app"
printf '%s\n' "$app"
