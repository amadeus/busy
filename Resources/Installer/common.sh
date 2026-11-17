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

installed_app_pids() {
    local candidates result=0 pid executable
    candidates="$(/usr/bin/pgrep -x BusyApp)" || result=$?
    [[ "$result" == 0 || "$result" == 1 ]] || fail 'Could not check whether Busy is running.'
    for pid in $candidates; do
        executable="$(/bin/ps -ww -p "$pid" -o comm=)" || continue
        if [[ "$executable" == /Applications/Busy.app/Contents/MacOS/BusyApp ]]; then
            printf '%s\n' "$pid"
        fi
    done
}

signal_installed_app() {
    local pid="$1" signal="$2" executable
    # Recheck each PID immediately before signaling; an unrelated executable
    # with the same process name must never be stopped by this installer.
    executable="$(/bin/ps -ww -p "$pid" -o comm=)" || return 0
    if [[ "$executable" == /Applications/Busy.app/Contents/MacOS/BusyApp ]]; then
        /bin/kill "-$signal" "$pid" 2>/dev/null || true
    fi
}

stop_installed_app() {
    local pids pid attempt
    pids="$(installed_app_pids)" || fail 'Could not check whether Busy is running.'
    [[ -n "$pids" ]] || return 0
    echo 'Busy installer: Stopping Busy before replacing the app.'
    for pid in $pids; do signal_installed_app "$pid" TERM; done

    # Busy handles TERM by releasing its power assertion and helper lease.
    # Allow the helper client's 15-second timeout before forcing a stuck exit.
    for ((attempt = 0; attempt < 20; attempt++)); do
        pids="$(installed_app_pids)" || fail 'Could not check whether Busy stopped.'
        [[ -n "$pids" ]] || return 0
        /bin/sleep 1
    done
    for pid in $pids; do signal_installed_app "$pid" KILL; done
    for ((attempt = 0; attempt < 5; attempt++)); do
        pids="$(installed_app_pids)" || fail 'Could not check whether Busy stopped.'
        [[ -n "$pids" ]] || return 0
        /bin/sleep 1
    done
    fail 'Could not stop Busy. Nothing has been replaced; quit Busy and run the installer again.'
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
