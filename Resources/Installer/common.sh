#!/bin/bash

fail() {
    echo "Busy installer: $*" >&2
    exit 1
}

require_system_target() {
    [[ "$EUID" == 0 ]] || fail 'Administrator privileges are required.'
    [[ "${3:-}" == / ]] || fail 'Busy must be installed on the current startup volume.'
    local version
    version="$(/usr/bin/sw_vers -productVersion)"
    [[ "${version%%.*}" -ge 14 ]] || fail 'Busy requires macOS 14 or later.'
}

require_app_stopped() {
    local result=0
    /usr/bin/pgrep -x BusyApp >/dev/null 2>&1 || result=$?
    [[ "$result" == 1 ]] || {
        if [[ "$result" == 0 ]]; then
            fail 'Quit Busy for all logged-in users, then run the installer again. You can use busy stop.'
        fi
        fail 'Could not check whether Busy is running. Quit Busy and try again.'
    }
}

reject_symlink() {
    [[ ! -L "$1" ]] || fail "Refusing a symbolic link at $1."
}

require_root_path() {
    local path="$1" kind="$2" private="${3:-false}" owner mode forbidden
    reject_symlink "$path"
    if [[ "$kind" == directory ]]; then
        [[ -d "$path" ]] || fail "Expected a directory at $path."
    else
        [[ -f "$path" ]] || fail "Expected a regular file at $path."
    fi
    owner="$(/usr/bin/stat -f %u "$path")"
    mode="$(/usr/bin/stat -f %Lp "$path")"
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ ]] || fail "Unsafe owner or permissions at $path."
    forbidden=0022
    if [[ "$private" == true ]]; then forbidden=0077; fi
    (( (8#$mode & forbidden) == 0 )) || fail "Unsafe permissions at $path."
}

read_authorized_uid() {
    local value
    require_root_path "$state_dir/config.json" file true
    value="$(/usr/bin/plutil -extract authorizedUID raw -o - "$state_dir/config.json")" || fail 'The existing helper configuration is invalid; it was preserved.'
    [[ "$value" =~ ^[0-9]+$ && "${#value}" -le 10 ]] || fail 'The existing helper user ID is invalid; configuration was preserved.'
    (( 10#$value > 0 && 10#$value < 4294967295 )) || fail 'The existing helper user ID must be a non-root user.'
    authorized_uid="$value"
}

helper_target=/Library/PrivilegedHelperTools/com.amadeus.Busy.helper
helper_plist=/Library/LaunchDaemons/com.amadeus.Busy.helper.plist
state_dir='/Library/Application Support/BusyHelper'
