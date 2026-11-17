#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
configuration="${CONFIGURATION:-release}"
case "$configuration" in debug|release) ;; *) echo 'CONFIGURATION must be debug or release.' >&2; exit 1 ;; esac
debug_info=none
if [[ "$configuration" == debug ]]; then debug_info=dwarf; fi

mkdir -p build/swift-cache build/module-cache
export CLANG_MODULE_CACHE_PATH="$project_dir/build/module-cache"
export SWIFT_MODULECACHE_PATH="$project_dir/build/module-cache"
swift build --disable-sandbox --configuration "$configuration" -debug-info-format "$debug_info" --cache-path "$project_dir/build/swift-cache"
binary_dir="$(swift build --disable-sandbox --configuration "$configuration" -debug-info-format "$debug_info" --cache-path "$project_dir/build/swift-cache" --show-bin-path)"
app_dir="$project_dir/build/Busy.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Library/LaunchServices"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp "$binary_dir/BusyApp" "$app_dir/Contents/MacOS/BusyApp"
cp "$binary_dir/busy" "$app_dir/Contents/MacOS/busy"
cp "$binary_dir/BusyHelper" "$app_dir/Contents/Library/LaunchServices/BusyHelper"
chmod 755 "$app_dir/Contents/MacOS/BusyApp" "$app_dir/Contents/MacOS/busy"

signing_identity="${SIGNING_IDENTITY:--}"
codesign --force --sign "$signing_identity" --options runtime "$app_dir/Contents/MacOS/busy"
codesign --force --sign "$signing_identity" --options runtime "$app_dir/Contents/Library/LaunchServices/BusyHelper"
codesign --force --sign "$signing_identity" --options runtime "$app_dir"
codesign --verify --deep --strict "$app_dir"
ln -sfn Busy.app/Contents/MacOS/busy build/busy
printf 'Built %s\nCLI: %s/build/busy\n' "$app_dir" "$project_dir"
