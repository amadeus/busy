#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_parent=/Applications
bin_dir="$HOME/.local/bin"
replace=false
while (($#)); do
    case "$1" in
        --app-dir|--bin-dir)
            option="$1"
            shift
            if (($# == 0)); then echo "Missing value for $option" >&2; exit 1; fi
            if [[ "$option" == --app-dir ]]; then app_parent="$1"; else bin_dir="$1"; fi
            ;;
        --replace) replace=true ;;
        --help|-h)
            printf '%s\n' 'Usage: ./scripts/install.sh [--app-dir DIR] [--bin-dir DIR] [--replace]' \
                'Defaults: /Applications/Busy.app and ~/.local/bin/busy.' \
                'Build first with ./scripts/build.sh. Quit Busy before replacing it.'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

source_app="$project_dir/build/Busy.app"
mkdir -p "$app_parent" "$bin_dir"
app_parent="$(cd "$app_parent" && pwd -P)"
bin_dir="$(cd "$bin_dir" && pwd -P)"
target_app="$app_parent/Busy.app"
target_cli="$bin_dir/busy"
if [[ ! -x "$source_app/Contents/MacOS/BusyApp" ]]; then echo 'Build Busy first with ./scripts/build.sh.' >&2; exit 1; fi
if [[ -e "$target_app" || -L "$target_app" ]]; then
    if [[ "$replace" != true ]]; then echo "$target_app already exists. Quit Busy and pass --replace to update it." >&2; exit 1; fi
    if [[ -L "$target_app" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist" 2>/dev/null)" != com.amadeus.Busy ]]; then
        echo "Refusing to replace an unrecognized app at $target_app." >&2; exit 1
    fi
fi
if [[ -e "$target_cli" || -L "$target_cli" ]]; then
    if [[ ! -L "$target_cli" || "$(readlink "$target_cli")" != "$target_app/Contents/MacOS/busy" ]]; then
        echo "Refusing to overwrite the existing command at $target_cli." >&2; exit 1
    fi
fi
source_app="$(cd "$source_app" && pwd -P)"
if [[ "$source_app" == "$target_app" ]]; then echo 'The install destination must differ from the build directory.' >&2; exit 1; fi
codesign --verify --deep --strict "$source_app"
staging_dir="$(mktemp -d "$app_parent/.busy-install.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
ditto "$source_app" "$staging_dir/Busy.app"
if [[ -e "$target_app" ]]; then mv "$target_app" "$staging_dir/previous.app"; fi
if ! mv "$staging_dir/Busy.app" "$target_app"; then
    if [[ -e "$staging_dir/previous.app" ]] && ! mv "$staging_dir/previous.app" "$target_app"; then
        trap - EXIT
        echo "Could not restore the previous app. It is preserved at $staging_dir/previous.app." >&2
    fi
    exit 1
fi
ln -sfn "$target_app/Contents/MacOS/busy" "$target_cli"
printf 'Installed %s\nCLI: %s\nEnsure %s is on your PATH.\n' "$target_app" "$target_cli" "$bin_dir"
