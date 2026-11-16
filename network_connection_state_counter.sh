#!/usr/bin/env bash
#
# network_connection_state_counter.sh
#
# Counts TCP sockets in each state by parsing /proc/net/tcp.
#
# The kernel exposes one line per socket in /proc/net/tcp. The state is a
# two-character hex field in column 4 (1-indexed). This library maps those
# codes to the names used by `ss`/`netstat` and aggregates counts.
#
# Design choices:
#   * We only read /proc/net/tcp (IPv4). /proc/net/tcp6 has the same layout
#     but a different address width; mixing them would double-count nothing
#     but would complicate the address parsing we do not need. Callers who
#     want both can call the counter twice with a different file.
#   * The state field is parsed case-insensitively because the kernel emits
#     uppercase hex but nothing guarantees that on every kernel version.
#   * Unknown state codes are bucketed under their raw code rather than
#     dropped, so a new kernel state does not silently vanish from totals.
#
# Exposes:
#   ncs_state_name CODE
#   ncs_count_file PATH
#   ncs_count_default

set -euo pipefail

# Map a two-hex-digit TCP state code to its conventional name.
#
# The codes come from include/net/tcp_states.h in the Linux kernel. We keep
# the mapping in a case statement instead of an associative array so the
# function works on bash 3 (macOS) as well as bash 4+.
ncs_state_name() {
    local code="${1:-}"
    # Normalise to uppercase without spawning tr, so we stay inside bash.
    code="${code^^}"
    case "$code" in
        01) printf '%s\n' 'ESTABLISHED' ;;
        02) printf '%s\n' 'SYN_SENT' ;;
        03) printf '%s\n' 'SYN_RECV' ;;
        04) printf '%s\n' 'FIN_WAIT1' ;;
        05) printf '%s\n' 'FIN_WAIT2' ;;
        06) printf '%s\n' 'TIME_WAIT' ;;
        07) printf '%s\n' 'CLOSE' ;;
        08) printf '%s\n' 'CLOSE_WAIT' ;;
        09) printf '%s\n' 'LAST_ACK' ;;
        0A) printf '%s\n' 'LISTEN' ;;
        0B) printf '%s\n' 'CLOSING' ;;
        0C) printf '%s\n' 'NEW_SYN_RECV' ;;
        *)  printf '%s\n' "UNKNOWN_${code}" ;;
    esac
}

# Count sockets per state in the given /proc/net/tcp-style file.
#
# Output is one line per state, "NAME COUNT", sorted by name so callers can
# diff two runs deterministically. A missing or unreadable file yields no
# output and a non-zero exit; an empty file (only the header) yields no
# output and exit 0. We do not print zero counts because the caller asked
# for states present in this snapshot, not a fixed taxonomy.
ncs_count_file() {
    local path="${1:-}"
    if [[ -z "$path" ]]; then
        printf 'ncs_count_file: missing path\n' >&2
        return 2
    fi
    if [[ ! -r "$path" ]]; then
        printf 'ncs_count_file: cannot read %s\n' "$path" >&2
        return 1
    fi

    # Associative array keyed by state name. Bash 3 lacks these, but the
    # target here is Linux where bash 4+ is the norm; the test suite pins
    # that assumption.
    declare -A counts=()

    local line code name
    # Skip the header line. `read` returns non-zero at EOF, which under
    # `set -e` would abort; the `|| [[ -n $line ]]` guard keeps the loop
    # running for a file whose last line lacks a trailing newline.
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Header detection: the first line starts with "  sl". Cheap and
        # sufficient; a data line always begins with whitespace then digits.
        case "$line" in
            *'local_address'*) continue ;;
        esac
        # Fields are whitespace-separated; the state is field 4.
        # shellcheck disable=SC2086
        set -- $line
        if [[ $# -lt 4 ]]; then
            continue
        fi
        code="$4"
        name="$(ncs_state_name "$code")"
        counts["$name"]=$(( ${counts["$name"]:-0} + 1 ))
    done < "$path"

    # Emit sorted. `printf` + `sort` is the only portable way to get
    # deterministic ordering out of an associative array.
    if [[ ${#counts[@]} -gt 0 ]]; then
        local key
        for key in "${!counts[@]}"; do
            printf '%s %d\n' "$key" "${counts[$key]}"
        done | sort
    fi
}

# Convenience wrapper for the live system table.
ncs_count_default() {
    ncs_count_file /proc/net/tcp
}
