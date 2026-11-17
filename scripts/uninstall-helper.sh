#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf '%s\n' 'Usage: sudo ./scripts/uninstall-helper.sh' \
        'Quit Busy first. Stop its helper, restore saved sleep settings, then remove it.'
    exit 0
fi
if (($# != 0)); then echo 'This command takes no arguments.' >&2; exit 1; fi
if [[ "$EUID" != 0 ]]; then echo 'Run this script with sudo.' >&2; exit 1; fi
if pgrep -x BusyApp >/dev/null; then echo 'Quit Busy before uninstalling its helper (busy stop).' >&2; exit 1; fi

helper_target=/Library/PrivilegedHelperTools/com.amadeus.Busy.helper
plist_target=/Library/LaunchDaemons/com.amadeus.Busy.helper.plist
state_dir='/Library/Application Support/BusyHelper'
if [[ ! -x "$helper_target" || -L "$helper_target" ]]; then
    echo 'The installed helper executable is missing or invalid; cannot safely restore sleep settings.' >&2; exit 1
fi
if launchctl print system/com.amadeus.Busy.helper >/dev/null 2>&1; then
    launchctl bootout system/com.amadeus.Busy.helper
fi
# Keep the journal and executable if restoration fails, so recovery can be retried.
if ! "$helper_target" --restore-only; then
    echo 'Sleep-setting restoration failed. Helper files were preserved; retry this command after resolving the error.' >&2
    exit 1
fi
rm -f "$helper_target" "$plist_target" "$state_dir/config.json" "$state_dir/journal.json" "$state_dir/helper.lock"
rmdir "$state_dir" 2>/dev/null || true
rm -f /var/run/com.amadeus.Busy/helper.sock
rmdir /var/run/com.amadeus.Busy 2>/dev/null || true
printf '%s\n' 'Restored sleep settings and removed the Busy closed-lid helper.'
