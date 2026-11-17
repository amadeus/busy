#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
case "${1:-}" in
    '') ./scripts/build.sh ;;
    --skip-build) [[ "$#" == 1 ]] || { echo 'Unexpected arguments.' >&2; exit 1; } ;;
    --help|-h)
        printf '%s\n' 'Usage: ./scripts/package.sh [--skip-build]' \
            'Build a macOS installer with Busy.app, busy, and an optional closed-lid helper.' \
            'Set SIGNING_IDENTITY for app signing and INSTALLER_SIGNING_IDENTITY for installer signing.'
        exit 0
        ;;
    *) echo 'Usage: ./scripts/package.sh [--skip-build]' >&2; exit 1 ;;
esac

app="$project_dir/build/Busy.app"
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo 'Invalid app version.' >&2; exit 1; }
architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/BusyApp")"
case "$architectures" in arm64|x86_64|'x86_64 arm64'|'arm64 x86_64') ;; *) echo 'Unsupported app architectures.' >&2; exit 1 ;; esac
for binary in "$app/Contents/MacOS/busy" "$app/Contents/Library/LaunchServices/BusyHelper"; do
    [[ "$(/usr/bin/lipo -archs "$binary")" == "$architectures" ]] || { echo 'App, CLI, and helper architectures must match.' >&2; exit 1; }
done
architectures="${architectures// /,}"
stage="$(mktemp -d "$project_dir/build/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/app/Applications" "$stage/app/usr/local/bin" \
    "$stage/helper/Library/PrivilegedHelperTools" "$stage/helper/Library/LaunchDaemons" \
    "$stage/app-scripts" "$stage/helper-scripts" "$stage/packages"
ditto "$app" "$stage/app/Applications/Busy.app"
ln -s /Applications/Busy.app/Contents/MacOS/busy "$stage/app/usr/local/bin/busy"
cp "$app/Contents/Library/LaunchServices/BusyHelper" "$stage/helper/Library/PrivilegedHelperTools/com.amadeus.Busy.helper"
cp Resources/com.amadeus.Busy.helper.plist "$stage/helper/Library/LaunchDaemons/com.amadeus.Busy.helper.plist"
chmod 755 "$stage/helper/Library/PrivilegedHelperTools/com.amadeus.Busy.helper"
chmod 644 "$stage/helper/Library/LaunchDaemons/com.amadeus.Busy.helper.plist"
cp Resources/Installer/app/preinstall Resources/Installer/common.sh "$stage/app-scripts/"
cp Resources/Installer/helper/preinstall Resources/Installer/helper/postinstall Resources/Installer/common.sh "$stage/helper-scripts/"
chmod 755 "$stage/app-scripts/preinstall" "$stage/helper-scripts/preinstall" "$stage/helper-scripts/postinstall"
chmod 644 "$stage/app-scripts/common.sh" "$stage/helper-scripts/common.sh"

pkgbuild --root "$stage/app" --install-location / --ownership recommended \
    --component-plist Resources/Installer/components.plist --scripts "$stage/app-scripts" \
    --identifier com.amadeus.Busy.pkg.app --version "$version" "$stage/packages/BusyApp.pkg"
pkgbuild --root "$stage/helper" --install-location / --ownership recommended \
    --scripts "$stage/helper-scripts" --identifier com.amadeus.Busy.pkg.helper \
    --version "$version" "$stage/packages/BusyHelper.pkg"
sed -e "s/@VERSION@/$version/g" -e "s/@ARCHITECTURES@/$architectures/g" \
    Resources/Installer/Distribution.xml > "$stage/Distribution.xml"

output="$project_dir/build/Busy-$version.pkg"
product_arguments=(--distribution "$stage/Distribution.xml" --package-path "$stage/packages" --resources Resources/Installer/ui)
if [[ -n "${INSTALLER_SIGNING_IDENTITY:-}" ]]; then product_arguments+=(--sign "$INSTALLER_SIGNING_IDENTITY"); fi
productbuild "${product_arguments[@]}" "$output"
printf 'Built %s\n' "$output"
