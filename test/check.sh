#!/bin/bash
# check.sh — the one-command gate for the OnionOS App/LodorSync shell surface (modeled on
# integrations/nextui/test/check.sh):
#   1. STATIC:  bash -n over every gated script, then a POSIX-family parse of the on-device
#      scripts — the on-device shell is OnionOS BUSYBOX ASH, so `busybox ash -n` is the
#      load-bearing parse (local busybox, else an amd64 busybox docker image, else dash /
#      dash-in-golang as the POSIX fallback); then shellcheck, with the BUSYBOX dialect
#      (--shell=busybox, ShellCheck >= 0.11.0) for the on-device files when the available
#      ShellCheck supports it — older versions keep the default dialect (gate not broken).
#   2. DYNAMIC: the full onion-sim scenario matrix (run-all.sh).
# Exit non-zero on any failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ONION="$(cd "$HERE/.." && pwd)"
APP="$ONION/App/LodorSync"
fails=0

# ---- the shell surface under gate ----
# POSIX_FILES run on-device under OnionOS busybox ash — they MUST parse in a POSIX shell
# and lint clean under the busybox dialect. bin/romm-syncd is a shell script despite the
# extensionless name (daemon convention). HARNESS_FILES are the x86-side sim scripts/stubs
# (POSIX sh, but they run on the CI host — default dialect). BASH_FILES are bash-only.
POSIX_FILES=(
	"$APP/launch.sh"
	"$APP/bin/lodor-launch.sh"
	"$APP/bin/lodor-seed.sh"
	"$APP/bin/romm-syncd"
	"$APP/lib/romm-sync-lib.sh"
)
HARNESS_FILES=(
	"$HERE/run-all.sh"
	"$HERE/integ-real.sh"
	"$HERE"/stubs/*
)
BASH_FILES=(
	"$HERE/check.sh"
	"$HERE/onion-sim.sh"
)
FILES=("${POSIX_FILES[@]}" "${HARNESS_FILES[@]}" "${BASH_FILES[@]}")

echo "== static: bash -n =="
for f in "${FILES[@]}"; do
	[ -f "$f" ] || { echo "GATE FAIL: missing $f"; fails=$((fails+1)); continue; }
	bash -n "$f" || { echo "GATE FAIL: bash -n $f"; fails=$((fails+1)); }
done

echo "== static: busybox-ash / POSIX parse =="
ROOT="$(cd "$ONION/../.." && pwd)"   # repo root — all gated files live under it
# Prefer a REAL busybox ash parse (the on-device shell). Docker candidates are PROBED with
# a `true` run: an image of the wrong arch (e.g. an arm32 busybox pulled for device work)
# exists but cannot exec — inspect alone would pick it and break the gate.
BB_IMG=""
if ! command -v busybox >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
	for img in busybox:1.36 busybox:stable busybox:latest; do
		if docker image inspect "$img" >/dev/null 2>&1 && docker run --rm "$img" true >/dev/null 2>&1; then
			BB_IMG="$img"; break
		fi
	done
fi
posix_parse() { # file -> 0 ok, 1 parse fail, 2 no parser
	local rel="${1#"$ROOT"/}"
	if command -v busybox >/dev/null 2>&1; then busybox ash -n "$1"
	elif [ -n "$BB_IMG" ]; then
		docker run --rm -v "$ROOT":/w -w /w "$BB_IMG" ash -n "$rel"
	elif command -v dash >/dev/null 2>&1; then dash -n "$1"
	elif command -v docker >/dev/null 2>&1 && docker image inspect golang:1.25-bookworm >/dev/null 2>&1; then
		docker run --rm -v "$ROOT":/w -w /w golang:1.25-bookworm dash -n "$rel"
	else
		return 2
	fi
}
posix_ok=1
for f in "${POSIX_FILES[@]}" "${HARNESS_FILES[@]}"; do
	[ -f "$f" ] || continue
	posix_parse "$f"; prc=$?
	if [ "$prc" = 2 ]; then
		echo "WARN: no busybox/dash/docker — POSIX parse skipped (bash -n still gates)"
		posix_ok=0; break
	elif [ "$prc" != 0 ]; then
		echo "GATE FAIL: POSIX/ash parse $f"; fails=$((fails+1))
	fi
done
[ "$posix_ok" = 1 ] && echo "POSIX parse: done${BB_IMG:+ (busybox ash via $BB_IMG)}"

echo "== static: shellcheck =="
# Pinned excludes — each reviewed against a REAL finding 2026-07-03 (busybox-dialect pass
# re-reviewed 2026-07-22); do NOT grow without a reason:
#   SC1090/SC1091  sources resolved at runtime ($SELF_DIR/../lib/…, $LIB) — not followable statically
#   SC1007         `CDPATH= cd -- …` — CDPATH deliberately cleared FOR the cd (the portable
#                  self-locate idiom); shellcheck misreads it as a botched assignment
#   SC2034         lib vars consumed by the scripts that SOURCE romm-sync-lib.sh (ROMS_ROOT →
#                  lodor-seed.sh, SAVES_ROOT → lodor-launch.sh, PENDING → all three) — contract,
#                  not dead; BIOS_ROOT/RA_DIR/PROGRESS are the documented card-layout/engine
#                  side-channel anchors, kept deliberately
SC_EXCLUDES="SC1090,SC1091,SC1007,SC2034"
# Probe which shellcheck we can reach and its version (SC_MODE: local | docker | none).
SC_MODE="none"; SC_VER=""
if command -v shellcheck >/dev/null 2>&1; then
	SC_MODE=local
	SC_VER="$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p' | head -1)"
elif command -v docker >/dev/null 2>&1 && docker image inspect koalaman/shellcheck:stable >/dev/null 2>&1; then
	SC_MODE=docker
	SC_VER="$(docker run --rm koalaman/shellcheck:stable --version 2>/dev/null | sed -n 's/^version: //p' | head -1)"
fi
sc_run() { # [extra flags...] -- files...
	case "$SC_MODE" in
		local) shellcheck -x -e "$SC_EXCLUDES" "$@" ;;
		docker)
			# PROBE the bind mount first: a docker CLI pointed at a REMOTE daemon (socket proxy)
			# would silently mount the remote host's paths instead of these files.
			printf '#!/bin/sh\n' > "$ROOT/.sc-probe.sh"
			if ! docker run --rm -v "$ROOT":/mnt koalaman/shellcheck:stable /mnt/.sc-probe.sh >/dev/null 2>&1; then
				rm -f "$ROOT/.sc-probe.sh"
				echo "WARN: docker daemon cannot see this filesystem (remote daemon?) — SKIPPING shellcheck"
				return 0
			fi
			rm -f "$ROOT/.sc-probe.sh"
			local flags=() rel=() f seen=0
			for f in "$@"; do
				if [ "$f" = "--" ]; then seen=1; continue; fi
				if [ "$seen" = 0 ]; then flags+=("$f"); else rel+=("${f#"$ROOT"/}"); fi
			done
			docker run --rm -v "$ROOT":/mnt -w /mnt koalaman/shellcheck:stable \
				-x -e "$SC_EXCLUDES" "${flags[@]}" "${rel[@]}"
			return $?
			;;
	esac
}
if [ "$SC_MODE" = none ]; then
	echo "WARN: shellcheck not available (no binary, no docker image) — SKIPPING lint (parse checks still ran)"
else
	# Busybox dialect for the ON-DEVICE files when supported (>= 0.11.0); the harness/bash
	# files always lint under their shebang dialect in a second, default run.
	sc_major="${SC_VER%%.*}"; sc_minor="${SC_VER#*.}"; sc_minor="${sc_minor%%.*}"
	case "$sc_major$sc_minor" in *[!0-9]*) sc_major=0; sc_minor=0 ;; esac
	if [ "${sc_major:-0}" -gt 0 ] || [ "${sc_minor:-0}" -ge 11 ]; then
		echo "shellcheck $SC_VER: busybox dialect for on-device files"
		if [ "$SC_MODE" = local ]; then
			sc_run --shell=busybox "${POSIX_FILES[@]}" || { echo "GATE FAIL: shellcheck (busybox dialect)"; fails=$((fails+1)); }
		else
			sc_run --shell=busybox -- "${POSIX_FILES[@]}" || { echo "GATE FAIL: shellcheck (busybox dialect)"; fails=$((fails+1)); }
		fi
	else
		echo "WARN: shellcheck $SC_VER lacks --shell=busybox (needs >= 0.11.0) — on-device files lint under the default dialect"
		if [ "$SC_MODE" = local ]; then
			sc_run "${POSIX_FILES[@]}" || { echo "GATE FAIL: shellcheck (POSIX files)"; fails=$((fails+1)); }
		else
			sc_run -- "${POSIX_FILES[@]}" || { echo "GATE FAIL: shellcheck (POSIX files)"; fails=$((fails+1)); }
		fi
	fi
	harness_existing=()
	for f in "${HARNESS_FILES[@]}" "${BASH_FILES[@]}"; do [ -f "$f" ] && harness_existing+=("$f"); done
	if [ "$SC_MODE" = local ]; then
		sc_run "${harness_existing[@]}" || { echo "GATE FAIL: shellcheck (harness files)"; fails=$((fails+1)); }
	else
		sc_run -- "${harness_existing[@]}" || { echo "GATE FAIL: shellcheck (harness files)"; fails=$((fails+1)); }
	fi
fi

echo "== static: run_menu top-level golden =="
# beta1 menu contract (T1.2/A): pin the EXACT top-level entry list run_menu passes to
# lodor_prompt. Any missing/renamed/reordered/added entry FAILS. The list is extracted
# from launch.sh directly (no execution) — the quoted args of the lodor_prompt call inside
# run_menu(), between `-m "RomM library sync"` and the trailing `_ms=$?`.
GOLDEN=$(printf '%s\n' \
	"Sync now" \
	"Refresh library" \
	"Download a game" \
	"Pull saves from server" \
	"Recent activity" \
	"Settings ▸")
GOT="$(awk '
	/^run_menu\(\)/ { inrm=1 }
	inrm && /_ms=\$\?/ { exit }
	inrm && cap {
		line=$0
		while (match(line, /"[^"]*"/)) {
			tok=substr(line, RSTART+1, RLENGTH-2)
			line=substr(line, RSTART+RLENGTH)
			if (tok=="Lodor" || tok=="RomM library sync") continue
			print tok
		}
	}
	inrm && /lodor_prompt -t "Lodor"/ { cap=1
		line=$0
		while (match(line, /"[^"]*"/)) {
			tok=substr(line, RSTART+1, RLENGTH-2)
			line=substr(line, RSTART+RLENGTH)
			if (tok=="Lodor" || tok=="RomM library sync") continue
			print tok
		}
	}
' "$APP/launch.sh")"
if [ "$GOT" = "$GOLDEN" ]; then
	echo "menu golden: OK (6 entries, Refresh library + Settings present)"
else
	echo "GATE FAIL: run_menu top-level list drifted from the golden"
	echo "--- want ---"; printf '%s\n' "$GOLDEN"
	echo "--- got ----"; printf '%s\n' "$GOT"
	fails=$((fails+1))
fi

# The dynamic sim matrix is its OWN fleet-check leg (onion-scenarios); when this check.sh is
# invoked static+golden-only (LODOR_CHECK_STATIC_ONLY=1, from fleet-check's onionos-static)
# we skip it here so run-all.sh does not run twice per fleet-check.
if [ "${LODOR_CHECK_STATIC_ONLY:-0}" = 1 ]; then
	echo "== dynamic: onion-sim scenario matrix — SKIPPED (LODOR_CHECK_STATIC_ONLY; runs as fleet-check onion-scenarios) =="
else
	echo "== dynamic: onion-sim scenario matrix =="
	sh "$HERE/run-all.sh" || fails=$((fails+1))
fi

echo "======================================================================"
if [ "$fails" = 0 ]; then
	echo "check.sh: ALL GATES PASSED"
	exit 0
fi
echo "check.sh: $fails gate(s) FAILED"
exit 1
