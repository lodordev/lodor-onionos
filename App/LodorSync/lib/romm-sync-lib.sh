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
SETTINGS="$DATA_DIR/settings.conf"       # engine key=value overlay (shell is the ONLY writer)

mkdir -p "$DATA_DIR" 2>/dev/null

log() { echo "$(date +'%F %T') $*" >> "$LOG" 2>/dev/null; }
phase() { echo "$1" > "$PHASE" 2>/dev/null; }   # HONEST: only call with a confirmed-true line

# --- Native OnionOS on-screen display (infoPanel). ----------------------------------------
# On the SSD202D Miyoo Mini the panel is driven by the SigmaStar MI-GFX layer, NOT raw
# /dev/fb0 — raw framebuffer writes never scan out under OnionOS (they only worked under
# LodorOS/MinUI because MinUI owns fb0 as the live surface). So we DO NOT draw the screen
# ourselves; we route every status line through OnionOS's OWN message binary, `infoPanel`
# (src/infoPanel), which renders via OnionOS's SDL/MI-GFX stack and actually scans out.
# infoPanel lives at .tmp_update/bin/infoPanel and is on PATH while an App runs (runtime.sh
# exports PATH=$sysdir/bin:$PATH + LD_LIBRARY_PATH). We resolve it absolutely + set
# LD_LIBRARY_PATH belt-and-suspenders so it works however this lib is reached.
#   ui_show   TITLE MSG  : PERSISTENT panel (stays up while a blocking op runs). Non-blocking;
#                          dismiss with ui_dismiss. infoPanel blocks on /tmp/dismiss_info_panel.
#   ui_dismiss           : tear down the persistent panel (touch the flag infoPanel waits on).
#   ui_result TITLE MSG  : blocking result screen — draws + waits for a button (--auto). Use
#                          for the final "done"/failure screen so the user reads it.
INFOPANEL=""
LODOR_UI_PID=""
lodor_infopanel() {
	if [ -z "$INFOPANEL" ]; then
		for c in "$SYSDIR/bin/infoPanel" "$SDCARD/.tmp_update/bin/infoPanel"; do
			[ -x "$c" ] && { INFOPANEL="$c"; break; }
		done
		[ -n "$INFOPANEL" ] || INFOPANEL="infoPanel"   # PATH fallback (runtime.sh exports it)
	fi
	# LD_LIBRARY_PATH so infoPanel's SDL/MI-GFX libs resolve even if our env didn't inherit it.
	LD_LIBRARY_PATH="/lib:/config/lib:$SDCARD/miyoo/lib:$SYSDIR/lib:$SYSDIR/lib/parasyte:${LD_LIBRARY_PATH:-}" \
		"$INFOPANEL" "$@"
}
ui_show() {   # TITLE MSG : persistent working panel (non-blocking; dismiss with ui_dismiss)
	ui_dismiss   # clear any prior panel + stale dismiss flag first
	rm -f /tmp/dismiss_info_panel 2>/dev/null
	lodor_infopanel --title "$1" --message "$2" --persistent >/dev/null 2>&1 &
	LODOR_UI_PID=$!
	log "ui_show: $1 — $2"
}
ui_dismiss() {   # tear down the persistent panel infoPanel is blocking on
	if [ -n "$LODOR_UI_PID" ]; then
		touch /tmp/dismiss_info_panel 2>/dev/null   # the flag infoPanel --persistent waits on
		_w=0
		while kill -0 "$LODOR_UI_PID" 2>/dev/null && [ "$_w" -lt 20 ]; do sleep 0.1; _w=$((_w+1)); done
		kill "$LODOR_UI_PID" 2>/dev/null
		LODOR_UI_PID=""
	fi
	rm -f /tmp/dismiss_info_panel 2>/dev/null
}
ui_result() {   # TITLE MSG : blocking result screen — draws + waits for a button
	ui_dismiss
	log "ui_result: $1 — $2"
	lodor_infopanel --title "$1" --message "$2" --auto >/dev/null 2>&1
}

# ui_progress_render TITLE PHASE PCT : persistent panel with an HONEST text progress bar.
# PCT/PHASE come STRAIGHT from the engine side-channels (/tmp/dl-progress, /tmp/romm-phase)
# — we never invent forward-progress (feedback_no_fake_ui_state). infoPanel on the Mini has
# no native bar flag and cannot be updated in place, so a change means kill+relaunch; we
# therefore redraw ONLY when the rendered text actually changes, so the panel does not
# flicker every poll. ASCII bar (#/-) because the OnionOS font is not guaranteed to carry
# block glyphs. infoPanel renders a literal backslash-n as a newline (dialog str_replace).
_LODOR_LAST_BAR=""
ui_progress_render() {
	_t="$1"; _phase="$2"; _pct="$3"
	case "$_pct" in ""|*[!0-9]*) _pct=0 ;; esac
	[ "$_pct" -gt 100 ] && _pct=100
	_fill=$(( _pct * 16 / 100 )); _i=0; _bar=""
	while [ "$_i" -lt 16 ]; do
		if [ "$_i" -lt "$_fill" ]; then _bar="${_bar}#"; else _bar="${_bar}-"; fi
		_i=$(( _i + 1 ))
	done
	[ -n "$_phase" ] || _phase="Syncing your RomM library..."
	_msg="${_phase}\\n \\n[${_bar}]  ${_pct}%"
	[ "$_msg" = "$_LODOR_LAST_BAR" ] && return 0
	_LODOR_LAST_BAR="$_msg"
	ui_show "$_t" "$_msg"
}

# run_with_progress TITLE -- <engine args...> : run a long engine mode in the background
# while rendering its REAL progress via ui_progress_render, polling the engine side-channels
# once a second until the mode exits. Returns the mode’s exit code. Engine stdout is captured
# to $LODOR_RUN_OUT (the caller greps the RESULT line from it) and appended to the log. No
# fabricated progress: if the engine writes nothing we simply hold the last honest value.
LODOR_RUN_OUT=""
run_with_progress() {
	_title="$1"; shift
	[ "${1:-}" = "--" ] && shift
	_LODOR_LAST_BAR=""
	LODOR_RUN_OUT="$DATA_DIR/.run.out"
	_rcf="$DATA_DIR/.run.rc"
	rm -f "$PROGRESS" "$PHASE" "$_rcf" 2>/dev/null
	: > "$LODOR_RUN_OUT"
	( lodor_engine "$@" > "$LODOR_RUN_OUT" 2>&1; echo $? > "$_rcf" ) &
	_rpid=$!
	while kill -0 "$_rpid" 2>/dev/null; do
		ui_progress_render "$_title" "$(cat "$PHASE" 2>/dev/null)" "$(cat "$PROGRESS" 2>/dev/null)"
		sleep 1
	done
	wait "$_rpid" 2>/dev/null
	cat "$LODOR_RUN_OUT" >> "$LOG" 2>/dev/null
	_rc=$(cat "$_rcf" 2>/dev/null); case "$_rc" in ""|*[!0-9]*) _rc=1 ;; esac
	return "$_rc"
}

# --- Interactive menu via OnionOS's native `prompt` SDL list picker. ----------------------
# `prompt` is OnionOS's reusable list widget (the minui-list analog for this lane): it draws
# a scrollable, selectable list through the SAME SDL/MI-GFX stack infoPanel uses (so it scans
# out on the SSD202D where raw /dev/fb0 does not), and returns the chosen 0-based index as its
# EXIT CODE (255 = B/cancel). Resolve it absolutely like infoPanel; LD_PRELOAD libpadsp so the
# menu move/select SFX resolve; bundled copy in bin/ is the fallback if a card's release omits
# .tmp_update/bin/prompt.  Usage: lodor_prompt -t TITLE [-m MSG] [-s SEL] ITEM... ; sel=$?
PROMPT=""
lodor_prompt() {
	if [ -z "$PROMPT" ]; then
		for c in "$SYSDIR/bin/prompt" "$SDCARD/.tmp_update/bin/prompt" "$APPDIR/bin/prompt"; do
			[ -x "$c" ] && { PROMPT="$c"; break; }
		done
		[ -n "$PROMPT" ] || PROMPT="prompt"   # PATH last resort (init_env exports it)
	fi
	# Inline LD_LIBRARY_PATH prefix ONLY - the exact form lodor_infopanel uses and that is
	# proven to render on this SSD202D card. Do NOT add LD_PRELOAD via ${var:+...}: a post-
	# expansion word is not re-parsed as an assignment prefix, so the shell tried to EXECUTE
	# "LD_PRELOAD=/path" as a command (rc=127) and prompt never launched - that bug made the
	# whole menu silently exit. libpadsp resolves via LD_LIBRARY_PATH if prompt needs it.
	LD_LIBRARY_PATH="/lib:/config/lib:$SDCARD/miyoo/lib:$SYSDIR/lib:$SYSDIR/lib/parasyte:${LD_LIBRARY_PATH:-}" "$PROMPT" "$@"
	return $?   # 0..N-1 = selected item; 255 = cancel (B)
}

# ============================================================================================
# Always-show launch card (task #80). Rendered with OnionOS `prompt` (MI-GFX; raw fb is dead
# on the SSD202D). Reimplements lodor-wizard --launch-card's model in shell: probe the server
# for saves/states, offer Play / Restore latest save / Restore a save state, dispatch to the
# engine, and ALWAYS fall through to launch. Caller gates on wifi_is_up (restore needs the
# server); offline just launches. Never blocks: B = Play, idle auto-Plays, any failure falls
# through. Honest-UX: labels reflect real probe results; never claims a state we didn't see.
# ============================================================================================
LC_IDLE=15                                   # seconds of no input before the card auto-Plays
LC_ST_DISP="/tmp/lodor-lc-states.disp"       # parallel files: display / id / slot, line-aligned
LC_ST_IDS="/tmp/lodor-lc-states.ids"
LC_ST_SLOTS="/tmp/lodor-lc-states.slots"

# lc_age SECS : humanize a state's age for the picker ("12m ago" / "3h ago" / "2d ago").
lc_age() {
	_s=${1:-0}
	case "$_s" in ''|*[!0-9]*) _s=0 ;; esac
	if   [ "$_s" -lt 3600 ];  then echo "$((_s/60))m ago"
	elif [ "$_s" -lt 86400 ]; then echo "$((_s/3600))h ago"
	else                           echo "$((_s/86400))d ago"
	fi
}

# lc_prompt IDLE TITLE MSG ITEM... : lodor_prompt with an idle auto-Play watchdog. Returns the
# selected 0-based index; 255 when the user cancels (B) OR the watchdog fires after IDLE secs
# (so an always-show card can never trap the Mini before a game). exec-in-subshell so $! is the
# real `prompt` pid the watchdog can kill.
lc_prompt() {
	_idle=$1; shift
	_p="$PROMPT"
	if [ -z "$_p" ]; then
		for c in "$SYSDIR/bin/prompt" "$SDCARD/.tmp_update/bin/prompt" "$APPDIR/bin/prompt"; do
			[ -x "$c" ] && { _p="$c"; break; }
		done
		[ -n "$_p" ] || _p="prompt"
	fi
	( export LD_LIBRARY_PATH="/lib:/config/lib:$SDCARD/miyoo/lib:$SYSDIR/lib:$SYSDIR/lib/parasyte:${LD_LIBRARY_PATH:-}"
	  exec "$_p" "$@" ) &
	_pp=$!
	( sleep "$_idle"; kill "$_pp" 2>/dev/null ) &
	_wp=$!
	wait "$_pp" 2>/dev/null; _rc=$?
	kill "$_wp" 2>/dev/null
	[ "$_rc" -gt 128 ] && _rc=255   # killed by the watchdog (signal) -> treat as Play
	return "$_rc"
}

# lc_dispatch TOKEN ROM : run the chosen card action against the engine (honest progress bar),
# show a brief result, and return. Never fatal — the caller launches regardless.
lc_dispatch() {
	_tk="$1"; _r="$2"
	case "$_tk" in
	RESTORE_SAVE)
		run_with_progress "$(basename "$_r")" -- --sync-save "$_r"; _dr=$?
		_res=$(grep '^RESULT ' "$LODOR_RUN_OUT" 2>/dev/null | tail -1)
		log "card restore-save rc=$_dr ${_res:-none}"
		if [ "$_dr" = 0 ]; then ui_result "Save restored" "Your latest save is on the card.\nLaunching..."
		else ui_result "Couldn't restore save" "Launching anyway.\n(see data/romm.log)"; fi
		;;
	RESTORE_STATE)
		[ -s "$LC_ST_DISP" ] || return 0
		set --
		while IFS= read -r _d; do [ -n "$_d" ] && set -- "$@" "$_d"; done < "$LC_ST_DISP"
		[ "$#" -gt 0 ] || return 0
		lc_prompt "$LC_IDLE" -t "Restore a save state" -m "B to go back" "$@"; _si=$?
		[ "$_si" = 255 ] && return 0
		_sid=$(sed -n "$((_si+1))p" "$LC_ST_IDS")
		_sslot=$(sed -n "$((_si+1))p" "$LC_ST_SLOTS")
		[ -n "$_sid" ] || return 0
		case "$_sslot" in
			''|*[!0-9]*) run_with_progress "Restoring state" -- --pull-state "$_r" --state-id "$_sid" ;;
			*)           run_with_progress "Restoring state" -- --pull-state "$_r" --state-id "$_sid" --state-slot "$_sslot" ;;
		esac
		_dr=$?
		_res=$(grep '^RESULT ' "$LODOR_RUN_OUT" 2>/dev/null | tail -1)
		log "card pull-state id=$_sid slot=$_sslot rc=$_dr ${_res:-none}"
		if printf '%s' "$_res" | grep -q 'placedstate=1'; then
			ui_result "State ready" "Load it from RetroArch's\nin-game menu. Launching..."
		else
			ui_result "Couldn't place state" "Launching anyway.\n(see data/romm.log)"
		fi
		;;
	esac
}

# lodor_launch_card ROM : the always-show pre-launch card. Probes saves+states (bounded),
# does the first-play silent pull (#135 safety), builds the action list, shows it with the
# idle watchdog, dispatches. Returns 0 always. Assumes Wi-Fi is up (caller gates).
lodor_launch_card() {
	_rom="$1"; _game=$(basename "$_rom")
	# -- probe saves (bounded) --
	_saves=$( ( cd "$DATA_DIR" 2>/dev/null && lodor_timeout 10 "$BIN" --list-saves "$_rom" ) 2>/dev/null ); _sr=$?
	_local=$(printf '%s\n' "$_saves" | sed -n 's/^LOCAL=//p' | tail -1)
	_nsaves=$(printf '%s\n' "$_saves" | awk -F'\t' 'NF>=2' | grep -c . 2>/dev/null)
	# -- probe states (always exits 0); build compat list newest-first into parallel files --
	_states=$( ( cd "$DATA_DIR" 2>/dev/null && lodor_timeout 10 "$BIN" --list-states "$_rom" ) 2>/dev/null ); _str=$?
	: > "$LC_ST_DISP"; : > "$LC_ST_IDS"; : > "$LC_ST_SLOTS"; rm -f "$LC_ST_DISP.news" 2>/dev/null
	_hasnews=0
	printf '%s\n' "$_states" | grep '^LISTSTATE ' | grep -F ' compat=1 ' | while IFS= read -r _line; do
		_age=$(printf '%s' "$_line" | sed -n 's/.* age=\([0-9]*\).*/\1/p')
		printf '%s\t%s\n' "${_age:-999999999}" "$_line"
	done | sort -n | head -20 | while IFS="$(printf '\t')" read -r _age _line; do
		_id=$(printf '%s' "$_line" | sed -n 's/.* id=\([0-9]*\).*/\1/p')
		_slot=$(printf '%s' "$_line" | sed -n 's/.* slot=\([^ ]*\).*/\1/p')
		_known=$(printf '%s' "$_line" | sed -n 's/.* known=\([0-9]*\).*/\1/p')
		_name=$(printf '%s' "$_line" | sed -n 's/.* name=\(.*\)$/\1/p')
		[ -n "$_id" ] || continue
		_tag=""; [ "$_known" = 0 ] && _tag=" (new)"
		printf '%s  -  %s%s\n' "${_name:-state}" "$(lc_age "$_age")" "$_tag" >> "$LC_ST_DISP"
		printf '%s\n' "$_id"   >> "$LC_ST_IDS"
		printf '%s\n' "$_slot" >> "$LC_ST_SLOTS"
		[ "$_known" = 0 ] && echo 1 >> "$LC_ST_DISP.news"
	done
	[ -s "$LC_ST_DISP.news" ] && _hasnews=1; rm -f "$LC_ST_DISP.news" 2>/dev/null
	_ncompat=$(grep -c . "$LC_ST_IDS" 2>/dev/null); : "${_ncompat:=0}"; : "${_nsaves:=0}"

	# -- first-play safety (#135): no local save yet -> silently pull the cloud save so a fresh
	#    device still gets it even if the user just hits Play. Unambiguous (nothing to clobber).
	if [ "$_sr" = 0 ] && [ "$_local" = "none" ] && [ "$_nsaves" -gt 0 ]; then
		( cd "$DATA_DIR" 2>/dev/null && lodor_timeout 25 "$BIN" --sync-save "$_rom" ) >> "$LOG" 2>&1
		log "card first-play silent pull (LOCAL=none) game=$_game"
		_local=current
	fi

	# -- build the action list (parallel token list in $_acts, newline-separated) --
	set -- "Play"; _acts="PLAY"
	if [ "$_sr" = 0 ] && [ "$_nsaves" -gt 0 ]; then
		if [ "$_local" = "older" ]; then set -- "$@" "Restore save (newer available)"
		else set -- "$@" "Restore latest save"; fi
		_acts="$_acts
RESTORE_SAVE"
	fi
	if [ "$_str" = 0 ] && [ "$_ncompat" -gt 0 ]; then
		if [ "$_hasnews" = 1 ]; then set -- "$@" "Restore a save state (new)"
		else set -- "$@" "Restore a save state"; fi
		_acts="$_acts
RESTORE_STATE"
	fi

	# -- offline / nothing to offer: a one-row Play card is friction -> just launch (skip) --
	if [ "$#" -le 1 ]; then
		log "card skipped (only Play; rc saves=$_sr states=$_str) game=$_game"
		return 0
	fi

	# -- show + dispatch --
	log "card show rows=$# local=$_local compat=$_ncompat news=$_hasnews game=$_game"
	lc_prompt "$LC_IDLE" -t "$_game" -m "Select an option, or press B to play" "$@"; _sel=$?
	if [ "$_sel" = 255 ]; then log "card action=play (cancel/idle) game=$_game"; return 0; fi
	_tok=$(printf '%s\n' "$_acts" | sed -n "$((_sel+1))p")
	log "card action=$_tok game=$_game"
	[ "$_tok" = "PLAY" ] && return 0
	lc_dispatch "$_tok" "$_rom"
	return 0
}


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

# --- settings.conf: the engine's key=value overlay (config/config.go overlays it from the
# engine CWD, which lodor_engine pins to $DATA_DIR). A handful of toggles (mirror_mode,
# fetch_covers) live here; the SHELL is the SINGLE writer, the engine only ever READS them.
# NEVER write these into config.json — the engine rewrites config.json on pairing and would
# clobber a hand-edit. tmp+rename so a died write never truncates the file; write is verified.
get_setting() {   # key -> value on stdout (empty if unset)
	sed -n "s/^$1=//p" "$SETTINGS" 2>/dev/null | head -1
}
set_setting() {   # key value : rewrite ONE key line, preserve the rest, verify it landed
	_sk="$1"; _sv="$2"; _tmp="$SETTINGS.tmp.$$"
	{ [ -f "$SETTINGS" ] && grep -v "^$_sk=" "$SETTINGS" 2>/dev/null; echo "$_sk=$_sv"; } > "$_tmp" 2>/dev/null \
		&& mv -f "$_tmp" "$SETTINGS" 2>/dev/null
	rm -f "$_tmp" 2>/dev/null
	[ "$(sed -n "s/^$_sk=//p" "$SETTINGS" 2>/dev/null | head -1)" = "$_sv" ]
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

# lodor_timeout SECS CMD... : busybox `timeout` syntax is not portable — some builds want
# the coreutils/new form `timeout SECS CMD`, older ones `timeout -t SECS CMD`. On this card
# the game-launch hook's timeout wanted `-t` (it tried to exec the bare "25" -> "timeout:
# can't execute '25'", rc=127, which silently killed pre-launch save-pull). Probe once with
# a no-op, dispatch to whichever works, and if neither does run WITHOUT a timeout (the engine
# self-limits via api_timeout/download_timeout, so the op is still bounded).
_LODOR_TO=""
lodor_timeout() {
	_ts=$1; shift
	if [ -z "$_LODOR_TO" ]; then
		if timeout "$_ts" true 2>/dev/null; then _LODOR_TO=new
		elif timeout -t "$_ts" true 2>/dev/null; then _LODOR_TO=old
		else _LODOR_TO=none; fi
	fi
	case "$_LODOR_TO" in
		new) timeout "$_ts" "$@" ;;
		old) timeout -t "$_ts" "$@" ;;
		*)   "$@" ;;
	esac
}

lodor_engine() {
	case "${1:-}" in
		--sync-save|--push-save|--push-pending|--pull-saves|--restore-save|\
		--push-states|--push-all-states|--push-pending-states|--queue-state|--pull-state) lodor_ensure_device ;;
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

# OnionOS stores the user's Wi-Fi credentials (SSID/PSK, entered via OnionOS's own Wi-Fi
# settings + keyboard) in /appconfigs/wpa_supplicant.conf. If that file is ABSENT the user
# has never configured Wi-Fi in OnionOS — there is nothing for us to bring up and we must
# NOT reimplement the keyboard/creds flow. wifi_configured lets callers show a clear "set up
# Wi-Fi in OnionOS first" message and exit cleanly instead of blank-failing.
WPA_CONF="/appconfigs/wpa_supplicant.conf"
wifi_configured() {
	# A real network block (ssid=) means creds are present, not just an empty stub file.
	[ -f "$WPA_CONF" ] && grep -q 'ssid=' "$WPA_CONF" 2>/dev/null
}

# wifi_bring_up return codes: 0 = up (creds present, associated + IP); 2 = NOT configured
# (no wpa_supplicant.conf — caller should tell the user to set up Wi-Fi in OnionOS); 1 =
# configured but couldn't connect. Callers distinguish 2 from 1 for an honest message.
wifi_bring_up() {
	wifi_is_up && { phase "Wi-Fi already connected"; set_clock || log "clock set failed (downloads may fail TLS)"; return 0; }
	if ! wifi_configured; then
		phase "Wi-Fi not set up in OnionOS"
		log "wifi_bring_up: $WPA_CONF absent/empty — user must configure Wi-Fi in OnionOS first"
		return 2
	fi
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

# --- transfer coordination mutex (ported from lodoros/nextui, liveness-correct) ----------
# Serializes ENGINE TRANSFERS across the daemon, romm-run (the app path), and anything else
# that syncs. Pure coordination — NO radio control (wifi_bring_up owns the network answer on
# this lane). mkdir-atomic; fg preempts a preemptible (push) holder so a user action never
# waits on a background save upload; bg (the daemon) never preempts and is never preempted.
# Reclaim ONLY a dead/absent owner — a LIVE holder keeps the mutex no matter how old its ts
# (long downloads are legitimate); the age constant is a tiebreak ONLY when kill -0 can't
# answer (unparseable owner pid).
_WIFI_LOCK="/tmp/romm-wifi.lock"
_WIFI_STALE=180   # age tiebreak: only consulted when owner liveness is inconclusive

# True while a LIVE actor holds the mutex (dead/absent-owner locks read as free).
_actor_active() {
	[ -d "$_WIFI_LOCK" ] || return 1
	o=$(cat "$_WIFI_LOCK/owner" 2>/dev/null); t=$(cat "$_WIFI_LOCK/ts" 2>/dev/null || echo 0); n=$(date +%s)
	case "$o" in
		'') return 1 ;;
		*[!0-9]*) [ $((n - t)) -le "$_WIFI_STALE" ] ;;
		*) kill -0 "$o" 2>/dev/null ;;
	esac
}

# wifi_acquire [mode]  mode: fg = user action (preempts a push holder) | push = post-game
# save upload (preemptible by fg) | bg = daemon (default). Returns 0 = mutex held (caller
# MUST wifi_release), 2 = busy (a live, non-preemptible holder). Never touches the radio.
wifi_acquire() {
	_acq_mode="${1:-bg}"
	while :; do
		if mkdir "$_WIFI_LOCK" 2>/dev/null; then
			echo "$$" > "$_WIFI_LOCK/owner"; date +%s > "$_WIFI_LOCK/ts"
			if [ "$_acq_mode" = push ]; then echo 1 > "$_WIFI_LOCK/preempt"; else rm -f "$_WIFI_LOCK/preempt" 2>/dev/null; fi
			[ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ] && break
			continue   # reclaimed during our setup window — re-evaluate
		fi
		owner=$(cat "$_WIFI_LOCK/owner" 2>/dev/null)
		ts=$(cat "$_WIFI_LOCK/ts" 2>/dev/null || echo 0); now=$(date +%s)
		_reclaim=0
		case "$owner" in
			'') _reclaim=1 ;;                                                   # absent owner
			*[!0-9]*) [ $((now - ts)) -gt "$_WIFI_STALE" ] && _reclaim=1 ;;     # unparseable: age tiebreak
			*) kill -0 "$owner" 2>/dev/null || _reclaim=1 ;;                    # parseable: liveness decides
		esac
		if [ "$_reclaim" = 1 ]; then
			rm -f "$_WIFI_LOCK/owner" "$_WIFI_LOCK/ts" "$_WIFI_LOCK/preempt" 2>/dev/null
			rmdir "$_WIFI_LOCK" 2>/dev/null
			continue   # retry the atomic mkdir; if we lose, we re-evaluate the new owner
		fi
		if [ "$_acq_mode" = fg ] && [ "$(cat "$_WIFI_LOCK/preempt" 2>/dev/null)" = 1 ]; then
			log "mutex PREEMPT push owner=$owner (fg incoming)"
			kill -TERM "-$owner" 2>/dev/null || kill -TERM "$owner" 2>/dev/null
			j=0; while kill -0 "$owner" 2>/dev/null && [ "$j" -lt 30 ]; do sleep 0.1; j=$((j + 1)); done
			continue   # holder dying -> loop reclaims the now-free lock
		fi
		log "wifi_acquire BUSY owner=$owner mode=$_acq_mode"
		return 2
	done
	return 0
}

# wifi_release — drop the mutex ONLY (owner-scoped: a trap/racer never disturbs another
# actor's transfer). Never touches the radio.
wifi_release() {
	if [ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ]; then
		rm -f "$_WIFI_LOCK/owner" "$_WIFI_LOCK/ts" "$_WIFI_LOCK/preempt" 2>/dev/null
		rmdir "$_WIFI_LOCK" 2>/dev/null
	fi
	return 0
}

# wifi_lock_refresh — bump the held lock's ts (owner-scoped; no-op otherwise). Long-cycle
# holders (the daemon between engine calls) call this so a reader that can't verify our
# liveness (unparseable-owner tiebreak) never mistakes a working holder for a stale one.
wifi_lock_refresh() {
	[ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ] && date +%s > "$_WIFI_LOCK/ts" 2>/dev/null
	return 0
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
