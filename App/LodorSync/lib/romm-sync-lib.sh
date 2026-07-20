#!/bin/sh
# romm-sync-lib.sh - shared OnionOS Lodor library. Sourced by lodor-launch.sh, lodor-seed.sh,
# romm-syncd, and the App launch.sh.  MARKER: LODOR_ONION_LIB
#
# HARD PRINCIPLES (carried from the MinUI + muOS builds, learned the hard way):
#  1. LEAN ON OnionOS'S STOCK MECHANISMS. Wi-Fi is OnionOS's job (update_networking.sh:
#     axp_test wifion + wpa_supplicant + udhcpc on wlan0); game launching is OnionOS's job
#     (the stock per-system Emu/<TAG>/launch.sh). We wrap them, never reinvent them.
#  2. HONEST UI. Every status line written to /tmp/romm-phase reflects CONFIRMED state. On
#     failure we write the SPECIFIC real reason, never fake forward-progress.
#  3. DETECT-AND-REHEAL. OnionOS overwrites Emu/ + .tmp_update on OS update; resolve paths
#     live and re-install our wraps on every daemon/app start, never trust a past layout.
#  4. LAUNCH IS NEVER GATED ON SYNC. Every sync step is best-effort + bounded; if anything
#     sync-related fails, the real emulator still runs (the load-bearing line is the stock
#     launcher hand-off).
#
# CGO-free POSIX sh (OnionOS busybox). No bashisms.

# --- OnionOS card layout (all env-overridable for the off-hardware sandbox) ------------
: "${SDCARD:=/mnt/SDCARD}"
SYSDIR="$SDCARD/.tmp_update"                  # OnionOS boot dir (updater + runtime.sh)
ROMS_ROOT="$SDCARD/Roms"
EMU_ROOT="$SDCARD/Emu"
SAVES_ROOT="$SDCARD/Saves/CurrentProfile/saves"
BIOS_ROOT="$SDCARD/BIOS"
RA_DIR="$SDCARD/RetroArch"

# --- App + data locations --------------------------------------------------------------
# APPDIR = where the engine binary + scripts live (the installed App/LodorSync/). DATA_DIR
# holds config.json, catalog-index.json, the pending queue, the log.
lodor_appdir() {
	if [ -n "${LODOR_APPDIR:-}" ]; then echo "$LODOR_APPDIR"; return 0; fi
	d="$SDCARD/App/LodorSync"
	[ -d "$d" ] && { echo "$d"; return 0; }
	echo "$SDCARD/App/LodorSync"
}

APPDIR="$(lodor_appdir)"
BIN="$APPDIR/lodor-sync"
DATA_DIR="$APPDIR/data"
LOG="$DATA_DIR/romm.log"
PHASE="/tmp/romm-phase"                  # honest one-line status the app reads
PROGRESS="/tmp/dl-progress"              # 0..100 the engine writes during downloads
INGAME_LOCK="/tmp/romm-in-game"
PENDING="$DATA_DIR/pending-saves.txt"

mkdir -p "$DATA_DIR" 2>/dev/null

log() { echo "$(date +'%F %T') $*" >> "$LOG" 2>/dev/null; }
phase() { echo "$1" > "$PHASE" 2>/dev/null; }   # HONEST: only call with a confirmed-true line

# Export the env the OnionOS engine build needs. The -tags onion binary already defaults
# to the OnionOS roots; we pin the pak/data dir + a CA bundle for HTTPS.
lodor_export_env() {
	export SDCARD BASE_PATH="$SDCARD"
	# LODOR_PAK_DIR points the engine at the data dir for catalog-index.json + the pending
	# queue. config.json, however, is loaded CWD-RELATIVE by the engine — so engine calls
	# MUST be made with cwd=$DATA_DIR (see lodor_engine). Both are needed.
	export LODOR_PAK_DIR="$DATA_DIR"
	mkdir -p "$DATA_DIR" 2>/dev/null
	if [ -z "${SSL_CERT_FILE:-}" ]; then
		for c in "$APPDIR/certs/ca-certificates.crt" /etc/ssl/certs/ca-certificates.crt; do
			[ -f "$c" ] && { export SSL_CERT_FILE="$c"; break; }
		done
	fi
}

# lodor_engine runs the engine binary with cwd=$DATA_DIR so it finds config.json (loaded
# CWD-relative) AND resolves the pak dir (catalog-index/pending) to the data dir. Every
# engine invocation in the pak goes through this — running $BIN directly from a launch
# CWD is the bug that made downloads fail with "open config.json: no such file".
# lodor_ensure_device: pairing self-heal, ported from the fleet (6b29c2c lineage).
# A preseeded/cloned config carries a token but no device_id — every save-sync mode
# hard-requires one, so such a card would silently never sync saves. Register once,
# here at the single engine funnel; failure is non-blocking (retried next call).
lodor_ensure_device() {
	[ -f "$DATA_DIR/config.json" ] || return 1
	grep -q -e '"device_id"' -e '"device_name"' "$DATA_DIR/config.json" 2>/dev/null && return 0
	grep -q '"token"' "$DATA_DIR/config.json" 2>/dev/null || return 1
	( cd "$DATA_DIR" 2>/dev/null || exit 1
	  "$BIN" --register-device "Miyoo Mini Plus (OnionOS)" ) >/dev/null 2>&1 || true
}

lodor_engine() {
	case "${1:-}" in
		--sync-save|--push-save|--push-pending|--pull-saves|--restore-save) lodor_ensure_device ;;
	esac
	( cd "$DATA_DIR" 2>/dev/null || exit 3; "$BIN" "$@" )
}

# --- Wi-Fi: lean on OnionOS's stock update_networking.sh. HARDWARE-DEFERRED. -----------
# OnionOS owns Wi-Fi (RTL8188FU on the MMP): axp_test wifion + wpa_supplicant -c
# /appconfigs/wpa_supplicant.conf + udhcpc on wlan0, all driven by update_networking.sh.
# We do NOT reinvent it. wifi_is_up checks for a real link; wifi_bring_up asks OnionOS to
# enable, then gates on association + a real IP. Honest status only.
wifi_is_up() {
	[ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = "up" ] || return 1
	ip addr show wlan0 2>/dev/null | grep -q "inet " || return 1
	return 0
}

# Reheal-locate OnionOS's network script (path stable in 4.x but resolve, don't assume).
lodor_net_script() {
	s="$SYSDIR/script/network/update_networking.sh"
	[ -x "$s" ] && { echo "$s"; return 0; }
	return 1
}

wifi_bring_up() {
	wifi_is_up && { phase "Wi-Fi already connected"; set_clock || log "clock set failed (downloads may fail TLS)"; return 0; }
	_ns="$(lodor_net_script)" || { phase "OnionOS network script not found"; return 1; }
	phase "Turning on Wi-Fi..."
	# OnionOS enables + connects via its own script (reads /appconfigs/wpa_supplicant.conf).
	"$_ns" enable  >/dev/null 2>&1 || "$_ns" check >/dev/null 2>&1
	_w=0
	while [ "$_w" -lt 30 ]; do
		wifi_is_up && { phase "Wi-Fi connected"; set_clock || log "clock set failed (downloads may fail TLS)"; return 0; }
		sleep 1; _w=$((_w + 1))
	done
	phase "Couldn't connect to Wi-Fi"   # SPECIFIC, honest - no fake success
	return 1
}

# set_clock - RTC-less handhelds (the MMP) boot to 1970, which makes every TLS cert look "not yet
# valid" -> the engine HTTPS fetch dies (DLFAIL getrom) and downloads/launches fail. Set the clock
# before any HTTPS, exactly like the working NextUI/my355 paks. NTP over UDP first (numeric Cloudflare
# IP, clock-independent), then a plain-HTTP Date header from the RomM host (pre-TLS). date -s needs
# root (the OnionOS App runs as root). Fast no-op once the year is already sane.
set_clock() {
	_yr=$(date +%Y 2>/dev/null)
	[ -n "$_yr" ] && [ "$_yr" -ge 2024 ] 2>/dev/null && return 0
	if command -v ntpd >/dev/null 2>&1 && ntpd -q -n -p 162.159.200.123 >/dev/null 2>&1; then return 0; fi
	if command -v sntp >/dev/null 2>&1 && sntp -sS 162.159.200.123 >/dev/null 2>&1; then return 0; fi
	_h=$(sed -n 's#.*"root_uri"[^"]*"https\{0,1\}://\([^/"]*\).*#\1#p' "$DATA_DIR/config.json" 2>/dev/null | head -1)
	if [ -n "$_h" ]; then
		_d=$(wget -S -q -O /dev/null "http://$_h/" 2>&1 | sed -n "s/^ *Date: //p" | head -1)
		[ -n "$_d" ] && date -s "$_d" >/dev/null 2>&1 && return 0
	fi
	return 1
}

# --- charging gate (daemon): MMP PMU sysfs. HARDWARE-DEFERRED node confirmation. -------
is_charging() {
	for n in /sys/class/power_supply/*/status; do
		[ -f "$n" ] || continue
		s="$(cat "$n" 2>/dev/null)"
		{ [ "$s" = "Charging" ] || [ "$s" = "Full" ]; } && return 0
	done
	return 1
}

creds_present() {
	[ -f "$DATA_DIR/config.json" ] || return 1
	grep -q '"token"' "$DATA_DIR/config.json" 2>/dev/null || grep -q '"password"' "$DATA_DIR/config.json" 2>/dev/null
}

not_in_game() {
	[ -f "$INGAME_LOCK" ] || return 0
	_p="$(cat "$INGAME_LOCK" 2>/dev/null)"
	[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && return 1
	rm -f "$INGAME_LOCK" 2>/dev/null   # stale lock (game killed) - reap
	return 0
}

# is_retroarch_emu <TAG> : true if Emu/<TAG>/launch.sh launches stock RetroArch (lr-style)
# rather than a standalone emulator. We only wrap RetroArch systems (our save model is the
# RetroArch per-core layout); standalone emulators (PICO-8 etc.) are left untouched so we
# never break their launch. Heuristic: the stock launch.sh references retroarch/.retroarch.
is_retroarch_emu() {
	_sh="$EMU_ROOT/$1/launch.stock.sh"
	[ -f "$_sh" ] || _sh="$EMU_ROOT/$1/launch.sh"
	[ -f "$_sh" ] || return 1
	grep -qiE "retroarch|\.retroarch|ra_dir|/RetroArch" "$_sh" 2>/dev/null
}
