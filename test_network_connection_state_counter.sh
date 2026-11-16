#!/usr/bin/env bash
#
# Tests for network_connection_state_counter.sh.
#
# Run with: bash test_network_connection_state_counter.sh
#
# The tests source the library and call its functions directly. Fixtures
# are written into a temporary directory so the suite never depends on the
# host's live /proc/net/tcp contents.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=network_connection_state_counter.sh
source "$HERE/network_connection_state_counter.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# assert_eq EXPECTED ACTUAL LABEL
#
# Compares two strings and prints a TAP-like line. Exits non-zero at the
# end of the suite if any assertion failed, so `set -e` callers see it.
assert_eq() {
    local expected="$1" actual="$2" label="${3:-assert_eq}"
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok - %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'not ok - %s\n' "$label"
        printf '  expected: %q\n' "$expected"
        printf '  actual:   %q\n' "$actual"
        FAIL=$((FAIL + 1))
    fi
}

# assert_status EXPECTED ACTUAL LABEL
#
# Same as assert_eq but for integer exit statuses, so the failure message
# reads naturally.
assert_status() {
    local expected="$1" actual="$2" label="${3:-assert_status}"
    if [[ "$expected" -eq "$actual" ]]; then
        printf 'ok - %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'not ok - %s\n' "$label"
        printf '  expected status: %d\n' "$expected"
        printf '  actual status:   %d\n' "$actual"
        FAIL=$((FAIL + 1))
    fi
}

# --- ncs_state_name ------------------------------------------------------

assert_eq 'ESTABLISHED' "$(ncs_state_name 01)" 'state 01 is ESTABLISHED'
assert_eq 'TIME_WAIT'   "$(ncs_state_name 06)" 'state 06 is TIME_WAIT'
assert_eq 'LISTEN'      "$(ncs_state_name 0A)" 'state 0A is LISTEN'
assert_eq 'LISTEN'      "$(ncs_state_name 0a)" 'state code is case-insensitive'
assert_eq 'UNKNOWN_FF'  "$(ncs_state_name FF)" 'unknown codes are preserved'
assert_eq 'UNKNOWN_'    "$(ncs_state_name '')" 'empty code yields UNKNOWN_ with empty suffix'

# --- ncs_count_file: happy path ------------------------------------------

cat > "$TMPDIR/basic" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F91 0100007F:1F92 01 00000000:00000000 00:00000000 00000000  1000        0 12346 1 0000000000000000 100 0 0 10 0
   2: 0100007F:1F93 0100007F:1F94 01 00000000:00000000 00:00000000 00000000  1000        0 12347 1 0000000000000000 100 0 0 10 0
   3: 0100007F:1F95 0100007F:1F96 06 00000000:00000000 00:00000000 00000000  1000        0 12348 1 0000000000000000 100 0 0 10 0
EOF

expected_basic=$'ESTABLISHED 2\nLISTEN 1\nTIME_WAIT 1'
actual_basic="$(ncs_count_file "$TMPDIR/basic")"
assert_eq "$expected_basic" "$actual_basic" 'basic table counts each state'

# --- ncs_count_file: empty table -----------------------------------------

cat > "$TMPDIR/empty" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
EOF

actual_empty="$(ncs_count_file "$TMPDIR/empty")"
assert_eq '' "$actual_empty" 'header-only table produces no output'

# --- ncs_count_file: unknown state codes ---------------------------------

cat > "$TMPDIR/unknown" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 FF 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
EOF

actual_unknown="$(ncs_count_file "$TMPDIR/unknown")"
assert_eq 'UNKNOWN_FF 1' "$actual_unknown" 'unknown state codes are surfaced, not dropped'

# --- ncs_count_file: missing file ----------------------------------------

set +e
ncs_count_file "$TMPDIR/does-not-exist" >/dev/null 2>&1
status=$?
set -e
assert_status 1 "$status" 'missing file returns status 1'

# --- ncs_count_file: empty path ------------------------------------------

set +e
ncs_count_file '' >/dev/null 2>&1
status=$?
set -e
assert_status 2 "$status" 'empty path returns status 2'

# --- ncs_count_file: short lines are skipped -----------------------------

cat > "$TMPDIR/short" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90
   1: 0100007F:1F91 0100007F:1F92 06 00000000:00000000 00:00000000 00000000  1000        0 12348 1 0000000000000000 100 0 0 10 0
EOF

actual_short="$(ncs_count_file "$TMPDIR/short")"
assert_eq 'TIME_WAIT 1' "$actual_short" 'lines with too few fields are ignored'

# --- ncs_count_file: no trailing newline ---------------------------------

printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0' > "$TMPDIR/no-newline"

actual_no_newline="$(ncs_count_file "$TMPDIR/no-newline")"
assert_eq 'LISTEN 1' "$actual_no_newline" 'last line without trailing newline is counted'

# --- ncs_count_file: output is sorted ------------------------------------

cat > "$TMPDIR/sorted" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 06 00000000:00000000 00:00000000 00000000  1000        0 1 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F91 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 2 1 0000000000000000 100 0 0 10 0
   2: 0100007F:1F92 00000000:0000 01 00000000:00000000 00:00000000 00000000  1000        0 3 1 0000000000000000 100 0 0 10 0
EOF

expected_sorted=$'ESTABLISHED 1\nLISTEN 1\nTIME_WAIT 1'
actual_sorted="$(ncs_count_file "$TMPDIR/sorted")"
assert_eq "$expected_sorted" "$actual_sorted" 'output is sorted by state name'

# --- ncs_count_default: signature only -----------------------------------
#
# We do not assert on the live /proc/net/tcp contents (they vary between
# machines and containers). We only assert that the function is callable
# and returns a non-negative status. This is the one test that touches the
# host, and it is deliberately weak.
set +e
ncs_count_default >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || "$status" -eq 1 ]]; then
    printf 'ok - ncs_count_default is callable\n'
    PASS=$((PASS + 1))
else
    printf 'not ok - ncs_count_default is callable (status %d)\n' "$status"
    FAIL=$((FAIL + 1))
fi

# --- summary -------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
