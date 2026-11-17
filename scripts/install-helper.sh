#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf '%s\n' 'Usage: sudo ./scripts/install-helper.sh' \
        'Install and start the closed-lid helper for the user invoking sudo.' \
        'Build Busy first. To replace an existing helper, uninstall it first.'
    exit 0
fi
if (($# != 0)); then echo 'This command takes no arguments.' >&2; exit 1; fi
if [[ "$EUID" != 0 || ! "${SUDO_UID:-}" =~ ^[0-9]+$ || "${SUDO_UID:-0}" == 0 ]]; then
    echo 'Run this script with sudo from the account that will use Busy.' >&2; exit 1
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
helper_source="$project_dir/build/Busy.app/Contents/Library/LaunchServices/BusyHelper"
helper_target=/Library/PrivilegedHelperTools/com.amadeus.Busy.helper
plist_target=/Library/LaunchDaemons/com.amadeus.Busy.helper.plist
state_dir='/Library/Application Support/BusyHelper'
if [[ ! -x "$helper_source" ]]; then echo 'Build Busy first with ./scripts/build.sh.' >&2; exit 1; fi
for destination in "$helper_target" "$plist_target" "$state_dir"; do
    if [[ -e "$destination" || -L "$destination" ]]; then
        echo "Existing helper files found at $destination. Run sudo ./scripts/uninstall-helper.sh first." >&2; exit 1
    fi
done
for parent in /Library/PrivilegedHelperTools /Library/LaunchDaemons '/Library/Application Support'; do
    if [[ -L "$parent" ]]; then echo "Refusing a symlinked system directory: $parent" >&2; exit 1; fi
done
codesign --verify --strict "$helper_source"
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
install -d -o root -g wheel -m 700 "$state_dir"
install -o root -g wheel -m 755 "$helper_source" "$helper_target"
install -o root -g wheel -m 644 "$project_dir/Resources/com.amadeus.Busy.helper.plist" "$plist_target"
umask 077
printf '{"authorizedUID":%s}\n' "$SUDO_UID" > "$state_dir/config.json"
chown root:wheel "$state_dir/config.json"
chmod 600 "$state_dir/config.json"
if ! launchctl bootstrap system "$plist_target"; then
    echo 'Helper startup failed. Keep its files in place and run sudo ./scripts/uninstall-helper.sh before retrying.' >&2
    exit 1
fi
printf 'Installed the Busy closed-lid helper for user ID %s. Relaunch Busy to use it.\n' "$SUDO_UID"
