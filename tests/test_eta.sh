#!/usr/bin/env bash
# Regression tests for _log_eta ETA calculation in lib/log.sh
# Tests that ETA decreases as progress increases at constant throughput.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null

failures=0
total=0

# Run a single check: _log_eta with given args, compare to expected output
check() {
    local desc="$1" t="$2" p="$3" r="$4" expected="$5"
    (( total++ )) || true
    local actual
    actual="$(_log_eta "$t" "$p" "$r" 2>/dev/null)"
    if [[ "$actual" == "$expected" ]]; then
        printf "  PASS  %-30s => %s\n" "$desc" "$actual"
    else
        printf "  FAIL  %-30s => expected '%s', got '%s'\n" "$desc" "$expected" "$actual"
        (( failures++ )) || true
    fi
}

echo "=== ETA Regression Tests ==="
echo ""

# --- Correctness: known values with constant total=100000, r=500 ---
echo "-- Progress sweep (t = p * 100000, r=500 t/s) --"
check "2% progress"    2000  0.02  500   "196.0s"
check "5% progress"    5000  0.05  500   "190.0s"
check "10% progress"  10000  0.10  500   "180.0s"
check "15% progress"  15000  0.15  500   "170.0s"
check "31% progress"  31000  0.31  500   "138.0s"
check "50% progress"  50000  0.50  500   "100.0s"
check "99% progress"  99000  0.99  500   "2.0s"

echo ""
echo "-- Completion / edge cases --"
check "100% progress"  100000  1.0   500   "0.0s"
check "p > 100%"       100000  1.5   500   "0.0s"
check "zero throughput" 10000  0.10  0     "--"
check "zero progress"    0     0     500   "--"
check "zero all"         0     0     0     "--"
check "very small p=0.001, t=1"  1  0.001  100  "10.0s"

echo ""
echo "-- Real-world data from llama.cpp print_timing --"
# These are the user's actual log values — corrected ETAs should be ~210-260s
# and should generally decrease after initial noise.
check "user line 1 (2%)"  2048   0.02   471.39  "212.9s"
check "user line 2 (4%)"  4096   0.04   451.14  "217.9s"
check "user line 3 (5%)"  6144   0.05   446.61  "261.4s"
check "user line 4 (7%)"  8192   0.07   442.22  "246.1s"
check "user line 5 (9%)"  10240  0.09   440.96  "234.8s"
check "user line 6 (11%)" 12288  0.11   439.83  "226.0s"

echo ""
echo "-- Monotonicity: ETA must decrease as progress increases --"
echo "  (Assumes constant total and throughput)"
eta_prev=999999
all_decreasing=true
for p_frac in 0.02 0.05 0.10 0.20 0.50 0.80 0.90; do
    t_int=$(awk -v p="$p_frac" 'BEGIN { printf "%d", p * 100000 }')
    eta="$(_log_eta "$t_int" "$p_frac" 500 2>/dev/null)"
    eta_num="${eta%s}"
    if awk -v a="$eta_num" -v b="$eta_prev" 'BEGIN { exit !(a+0 > b+0) }'; then
        echo "  WARNING: ETA increased from $eta_prev to $eta_num at progress=$p_frac"
        all_decreasing=false
    fi
    eta_prev="$eta_num"
done
if $all_decreasing; then
    echo "  PASS: ETA monotonically decreases across all progress levels"
else
    echo "  FAIL: ETA did not monotonically decrease"
    (( failures++ )) || true
fi

echo ""
echo "=== Results: $total tests, $failures failures ==="

# Also show the full monotonicity table
echo ""
echo "=== Monotonicity Table ==="
echo "  Progress | Processed | Throughput | ETA"
printf "  %6s | %9s | %10s | %s\n" "0.02" "2000" "500" "$(_log_eta 2000 0.02 500 2>/dev/null)"
printf "  %6s | %9s | %10s | %s\n" "0.05" "5000" "500" "$(_log_eta 5000 0.05 500 2>/dev/null)"
printf "  %6s | %9s | %10s | %s\n" "0.10" "10000" "500" "$(_log_eta 10000 0.10 500 2>/dev/null)"
printf "  %6s | %9s | %10s | %s\n" "0.20" "20000" "500" "$(_log_eta 20000 0.20 500 2>/dev/null)"
printf "  %6s | %9s | %10s | %s\n" "0.50" "50000" "500" "$(_log_eta 50000 0.50 500 2>/dev/null)"
printf "  %6s | %9s | %10s | %s\n" "0.80" "80000" "500" "$(_log_eta 80000 0.80 500 2>/dev/null)"
printf "  %6s | %9s | %10s | %s\n" "0.90" "90000" "500" "$(_log_eta 90000 0.90 500 2>/dev/null)"

exit "$failures"
