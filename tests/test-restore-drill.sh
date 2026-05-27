#!/usr/bin/env bash
# test-restore-drill.sh — self-test of tests/restore-drill.sh.
#
# Runs the drill in four shapes that any change to the drill script
# should keep working:
#
#   1. Happy path, --verbose:   pass, exit 0, output contains "PASSED"
#   2. Happy path, silent:      pass, exit 0, no output (cron-friendly)
#   3. Bad host (no config):    fail, exit 1, error message mentions ".toml not present"
#   4. Symlink file refused:    fail, exit 1, error message mentions "symlink"
#
# Run manually after changing tests/restore-drill.sh to confirm no
# regressions. Not on cron (it talks to live hosts; we don't want
# the noise).
#
# Requires: at least one configured + bootstrapped host in
# configs/hosts/. By default uses arrow-iii (a known-stable target).
#
# Usage:
#   tests/test-restore-drill.sh [<host>]

set -uo pipefail

HOST="${1:-arrow-iii}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRILL="$SCRIPT_DIR/restore-drill.sh"

PASS=0
FAIL=0
FAILED_CASES=()

run_case() {
    local label="$1"
    local expected_exit="$2"
    local must_contain="$3"
    shift 3

    echo -n "  case: $label ... "
    local out
    out=$("$DRILL" "$@" 2>&1)
    local rc=$?

    if [ "$rc" -ne "$expected_exit" ]; then
        echo "FAIL (exit $rc, expected $expected_exit)"
        echo "    output: $out" | head -3
        FAIL=$((FAIL+1))
        FAILED_CASES+=("$label")
        return
    fi

    if [ -n "$must_contain" ]; then
        if echo "$out" | grep -q "$must_contain"; then
            echo "PASS"
            PASS=$((PASS+1))
        else
            echo "FAIL (expected output to contain '$must_contain')"
            echo "    got: $out" | head -3
            FAIL=$((FAIL+1))
            FAILED_CASES+=("$label")
        fi
    else
        # No content requirement — but must be SILENT
        if [ -z "$out" ]; then
            echo "PASS"
            PASS=$((PASS+1))
        else
            echo "FAIL (expected silent output, got: $(echo "$out" | head -1))"
            FAIL=$((FAIL+1))
            FAILED_CASES+=("$label")
        fi
    fi
}

echo "================ test-restore-drill.sh — using host: $HOST ================"
echo

# 1. Happy path, --verbose — should pass + print three hashes
run_case "happy-path verbose"      0 "PASSED"                    "$HOST" --verbose

# 2. Happy path, silent (no --verbose) — should pass + print nothing
run_case "happy-path silent"       0 ""                          "$HOST"

# 3. Nonexistent host — preflight should bail with config-missing message
run_case "nonexistent host"        1 "not present"               nonexistent-host

# 4. Symlink file (e.g., /etc/os-release on linux) — should refuse
run_case "symlink file refused"    1 "symlink"                   "$HOST" /etc/os-release

echo
if [ "$FAIL" -eq 0 ]; then
    echo "✓ all $PASS cases passed"
    exit 0
else
    echo "✗ $FAIL of $((PASS+FAIL)) cases FAILED:"
    for c in "${FAILED_CASES[@]}"; do echo "    - $c"; done
    exit 1
fi
