#!/bin/sh
# run-all.sh — run every scenario in scenarios/ through onion-sim.sh; PASS/FAIL per line,
# summary at the end, exit non-zero on any FAIL. Optional args: scenario names (sans .scn)
# to run a subset, e.g. `./run-all.sh c-card-play-default m-menu-sync-now`.
# POSIX sh (fleet-check.sh invokes it as `sh run-all.sh`). Scenarios MUST run sequentially:
# the onion lib pins fixed /tmp names (romm-phase, romm-wifi.lock, lodor-lc-states.*).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 2

if [ $# -gt 0 ]; then
	set -- "$@"
	names=""
	for a in "$@"; do names="$names scenarios/$a.scn"; done
	# shellcheck disable=SC2086  # intentional word-split of the rebuilt list
	set -- $names
else
	set -- scenarios/*.scn
fi

pass=0; failn=0; failed=""
start=$(date +%s)
for scn in "$@"; do
	[ -f "$scn" ] || { echo "FAIL  $scn — scenario file not found"; failn=$((failn+1)); failed="$failed $(basename "$scn" .scn)"; continue; }
	if bash ./onion-sim.sh "$scn"; then
		pass=$((pass+1))
	else
		failn=$((failn+1)); failed="$failed $(basename "$scn" .scn)"
	fi
done
dur=$(( $(date +%s) - start ))
echo "----------------------------------------------------------------------"
echo "onion-sim: $pass passed, $failn failed (${dur}s)"
[ "$failn" = 0 ] || { echo "failed:$failed"; exit 1; }
exit 0
