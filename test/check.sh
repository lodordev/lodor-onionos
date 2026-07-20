#!/bin/bash
# check.sh — static gate for the OnionOS App/LodorSync shell surface (modeled on
# integrations/nextui/test/check.sh's static leg):
#   1. bash -n over every gated script (catches gross syntax damage fast).
#   2. POSIX parse (dash -n, else busybox ash -n, else dash inside the golang build
#      image) — the on-device shell is OnionOS busybox ash, so a POSIX-family parse
#      is the load-bearing check; bash -n alone would bless bashisms the card can't run.
#   3. shellcheck (local binary, else the koalaman/shellcheck docker image, else skipped
#      with a warning — parse checks still gate).
# Exit non-zero on any failure. The dynamic leg for this surface is the release gates
# (release/gate.sh over the staged zip) + the engine's own test suite — not duplicated here.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ONION="$(cd "$HERE/.." && pwd)"
APP="$ONION/App/LodorSync"
fails=0

# ---- the shell surface under gate ----
# POSIX_FILES run on-device under OnionOS busybox ash — they MUST parse in a POSIX shell.
# bin/romm-syncd is a shell script despite the extensionless name (daemon convention).
POSIX_FILES=(
	"$APP/launch.sh"
	"$APP/bin/lodor-launch.sh"
	"$APP/bin/lodor-seed.sh"
	"$APP/bin/romm-syncd"
	"$APP/lib/romm-sync-lib.sh"
)
BASH_FILES=(
	"$HERE/check.sh"
)
FILES=("${POSIX_FILES[@]}" "${BASH_FILES[@]}")

echo "== static: bash -n =="
for f in "${FILES[@]}"; do
	[ -f "$f" ] || { echo "GATE FAIL: missing $f"; fails=$((fails+1)); continue; }
	bash -n "$f" || { echo "GATE FAIL: bash -n $f"; fails=$((fails+1)); }
done

echo "== static: POSIX-sh parse =="
# POSIX parser: dash where present (dev container / debian), else busybox ash, else dash
# inside the golang build image (always present wherever the engine builds — panther has
# neither dash nor busybox on PATH, so the docker leg is what actually runs there).
posix_parse() { # file
	if command -v dash >/dev/null 2>&1; then dash -n "$1"
	elif command -v busybox >/dev/null 2>&1; then busybox ash -n "$1"
	elif command -v docker >/dev/null 2>&1 && docker image inspect golang:1.25-bookworm >/dev/null 2>&1; then
		local rel="${1#"$ROOT"/}"
		docker run --rm -v "$ROOT":/w -w /w golang:1.25-bookworm dash -n "$rel"
	else
		return 2
	fi
}
ROOT="$(cd "$ONION/../.." && pwd)"   # repo root — all gated files live under it
posix_ok=1
for f in "${POSIX_FILES[@]}"; do
	[ -f "$f" ] || continue
	posix_parse "$f"; rc=$?
	if [ "$rc" = 2 ]; then
		echo "WARN: no dash/busybox/docker — POSIX parse skipped (bash -n still gates)"
		posix_ok=0; break
	elif [ "$rc" != 0 ]; then
		echo "GATE FAIL: POSIX parse $f"; fails=$((fails+1))
	fi
done
[ "$posix_ok" = 1 ] && echo "POSIX parse: done"

echo "== static: shellcheck =="
# Pinned excludes — each reviewed against a REAL finding 2026-07-03; do NOT grow without a reason:
#   SC1090/SC1091  sources resolved at runtime ($SELF_DIR/../lib/…, $LIB) — not followable statically
#   SC1007         `CDPATH= cd -- …` — CDPATH deliberately cleared FOR the cd (the portable
#                  self-locate idiom); shellcheck misreads it as a botched assignment
#   SC2034         lib vars consumed by the scripts that SOURCE romm-sync-lib.sh (ROMS_ROOT →
#                  lodor-seed.sh, SAVES_ROOT → lodor-launch.sh, PENDING → all three) — contract,
#                  not dead; BIOS_ROOT/RA_DIR/PROGRESS are the documented card-layout/engine
#                  side-channel anchors, kept deliberately
SC_EXCLUDES="SC1090,SC1091,SC1007,SC2034"
run_shellcheck() {
	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck -x -e "$SC_EXCLUDES" "$@"
	elif command -v docker >/dev/null 2>&1 && docker image inspect koalaman/shellcheck:stable >/dev/null 2>&1; then
		# PROBE the bind mount first: a docker CLI pointed at a REMOTE daemon (socket proxy)
		# would silently mount the remote host's paths instead of these files.
		printf '#!/bin/sh\n' > "$ROOT/.sc-probe.sh"
		if ! docker run --rm -v "$ROOT":/mnt koalaman/shellcheck:stable /mnt/.sc-probe.sh >/dev/null 2>&1; then
			rm -f "$ROOT/.sc-probe.sh"
			echo "WARN: docker daemon cannot see this filesystem (remote daemon?) — SKIPPING shellcheck"
			return 0
		fi
		rm -f "$ROOT/.sc-probe.sh"
		local rel=() f
		for f in "$@"; do rel+=("${f#"$ROOT"/}"); done
		docker run --rm -v "$ROOT":/mnt -w /mnt koalaman/shellcheck:stable \
			-x -e "$SC_EXCLUDES" "${rel[@]}"
	else
		echo "WARN: shellcheck not available (no binary, no docker image) — SKIPPING lint (parse checks still ran)"
		return 0
	fi
}
existing=()
for f in "${FILES[@]}"; do [ -f "$f" ] && existing+=("$f"); done
run_shellcheck "${existing[@]}" || { echo "GATE FAIL: shellcheck"; fails=$((fails+1)); }

echo "======================================================================"
if [ "$fails" = 0 ]; then
	echo "check.sh: ALL GATES PASSED"
	exit 0
fi
echo "check.sh: $fails gate(s) FAILED"
exit 1
