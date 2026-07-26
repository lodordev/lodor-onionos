#!/bin/sh
# launch.sh - the "Lodor" entry under the OnionOS Apps tab. MainUI runs this when the
# app is selected (CWD = this folder).  MARKER: LODOR_APP
#
# DISPLAY: OnionOS's OWN message binary, `infoPanel` (routed via lib's ui_show/ui_result),
# which renders through OnionOS's SDL/MI-GFX stack and actually scans out on the SSD202D
# Miyoo Mini. We do NOT draw the framebuffer ourselves — raw /dev/fb0 writes never scan out
# under OnionOS (that path was dead: bin/lodor-menu exited rc=20 to a blank screen). There
# is NO raw-fb draw anywhere in this OnionOS App path.
#
# FLOW: opening "Lodor" shows an interactive options menu (run_menu) via OnionOS's native
# `prompt` SDL list picker (MI-GFX; raw /dev/fb0 is dead on the SSD202D). Top level:
#   Sync now / Refresh library / Download a game / Pull saves / Recent activity / Settings.
# If `prompt` is somehow absent on the card we degrade to auto-sync-on-open (never a blank
# screen). HONESTY (feedback_no_fake_ui_state): a step is shown "done" ONLY after the engine
# actually returned 0; failures show the SPECIFIC real cause; never fake forward-progress.
#
# Host rendering ONLY. ALL RomM logic stays in the engine, reached through the lib's
# lodor_engine / wifi_bring_up / set_clock.
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LODOR_APPDIR="$SELF_DIR"
export LODOR_HOST_OS=onion   # engine host-OS lane tag (roots/save rule). Display = infoPanel, NOT raw-fb.
. "$SELF_DIR/lib/romm-sync-lib.sh"
lodor_export_env

LASTSYNC="$DATA_DIR/last-sync.txt"

# -- Defensive takeover (harmless): MainUI has usually already exited by the time an App's
# launch.sh runs, so this is belt-and-suspenders — STOP it if it's somehow still up so it
# can't fight infoPanel for the display, CONT it on exit. Never fatal if MainUI is gone.
kill -STOP "$(pidof MainUI)" 2>/dev/null || true
trap 'kill -CONT $(pidof MainUI) 2>/dev/null; ui_dismiss; wifi_release 2>/dev/null' EXIT INT TERM HUP QUIT

note_synced() { date +'%F %T' > "$LASTSYNC" 2>/dev/null; }

# -- diagnose a non-zero engine rc into an HONEST cause line (cheap local preconditions first).
# infoPanel renders LITERAL "\n" as a newline itself (dialog.h str_replace), so we emit the
# backslash-n literally with printf '%s' — echo would (busybox) expand it and break wrapping.
diagnose() {
	if   ! creds_present; then printf '%s' 'Not configured.\nAdd your RomM server + token to\nApp/LodorSync/data/config.json,\nthen reopen the Lodor app.'
	elif ! wifi_is_up;    then printf '%s' "Wi-Fi dropped.\n$(cat "$PHASE" 2>/dev/null)"
	elif [ "${1:-1}" = 3 ]; then printf '%s' 'Couldn'\''t reach your RomM server.\nCheck the server URL + token.\n(log: data/romm.log)'
	else                       printf '%s' "Sync failed (rc=${1:-?}).\nSee data/romm.log."
	fi
}

# -- ensure Wi-Fi + clock; leaves an honest result screen and returns non-zero on failure.
#    Wi-Fi-not-set-up in OnionOS (wifi_bring_up rc=2) gets its OWN clear message and exits
#    cleanly — we never reimplement the keyboard/creds flow.
ensure_online() {  # title
	if ! creds_present; then
		ui_result "$1" "Not configured.\n \nAdd your RomM server + pairing token to:\nApp/LodorSync/data/config.json\n(see config.json.example),\nthen reopen the Lodor app."
		return 1
	fi
	ui_show "$1" "Connecting to Wi-Fi..."
	wifi_bring_up; _wrc=$?
	if [ "$_wrc" = 2 ]; then
		ui_result "$1" "Wi-Fi isn't set up yet.\n \nOpen OnionOS Wi-Fi settings, join your\nnetwork, then reopen the Lodor app."
		return 1
	elif [ "$_wrc" != 0 ]; then
		ui_result "$1" "Couldn't connect to Wi-Fi.\n$(cat "$PHASE" 2>/dev/null)\n \nCheck your Wi-Fi in OnionOS, then retry."
		return 1
	fi
	return 0
}

# -- the one-shot auto-sync: push pending saves, then mirror the library. Both run in the
#    background under run_with_progress so the user sees a REAL, engine-driven progress bar
#    (the mirror is the long step that used to stall on a static "Syncing..." line).
do_sync_now() {
	ensure_online "Lodor" || return
	_rc=0
	if [ -s "$PENDING" ]; then
		run_with_progress "Lodor" -- --push-pending || _rc=$?
	fi
	# A hands-on Sync now force-pushes EVERY on-card save state (not just the pending queue),
	# so a manual sync guarantees all states are up. Best-effort — a state hiccup must not
	# fail the save/mirror sync (parity: NextUI launch.sh:978).
	run_with_progress "Lodor" -- --push-all-states || true
	run_with_progress "Lodor" -- --mirror-catalog; _r2=$?
	[ "$_r2" -gt "$_rc" ] && _rc=$_r2
	MIRROR=$(cat "$LODOR_RUN_OUT" 2>/dev/null)
	if [ "$_rc" = 0 ]; then
		note_synced
		_sum=$(echo "$MIRROR" | grep -i "^MIRROR" | head -1)
		ui_result "Sync complete" "${_sum:-Library synced.}\n \nRefresh your Games list to\nsee new titles."
	else
		ui_result "Sync failed" "$(diagnose "$_rc")"
	fi
}

# -- Refresh library (T1.2): FULL re-mirror (re-fetches every cover). The long one; its own
#    honest button so the fast "Sync now" incremental mirror stays snappy. -------------------
do_refresh_library() {
	ensure_online "Lodor" || return
	run_with_progress "Lodor" -- --mirror-catalog --full; _rc=$?
	MIRROR=$(cat "$LODOR_RUN_OUT" 2>/dev/null)
	if [ "$_rc" = 0 ]; then
		note_synced
		_sum=$(echo "$MIRROR" | grep -i "^MIRROR" | head -1)
		ui_result "Library refreshed" "${_sum:-Library refreshed.}\n \nRefresh your Games list to\nsee new titles + box art."
	else
		ui_result "Refresh failed" "$(diagnose "$_rc")"
	fi
}

# -- Pull the newest saves from the server (headless-safe; shows a real bar). ---------------
do_pull_saves() {
	ensure_online "Lodor" || return
	run_with_progress "Lodor" -- --pull-saves; _r=$?
	OUT=$(cat "$LODOR_RUN_OUT" 2>/dev/null)
	if [ "$_r" = 0 ]; then
		_sum=$(echo "$OUT" | grep -iE "^(PULL|SAVES)" | head -1)
		ui_result "Saves pulled" "${_sum:-Your saves are up to date.}"
	else
		ui_result "Pull failed" "$(diagnose "$_r")"
	fi
}

# -- Recent cross-device activity (read-only). --------------------------------------------
do_recent() {
	ensure_online "Lodor" || return
	ui_show "Lodor" "Fetching recent activity..."
	FEED=$(lodor_engine --recent 2>/dev/null | grep -v "^RESULT" | sed "/^[[:space:]]*$/d")
	ui_dismiss
	if [ -z "$FEED" ]; then
		ui_result "Recent activity" "Nothing recent yet.
 
Play a game or sync a save and it
shows up here."
		return
	fi
	# Render as a read-only prompt list (scrollable; A/B both just exit).
	set --
	while IFS= read -r _line; do [ -n "$_line" ] && set -- "$@" "$_line"; done <<REOF
$FEED
REOF
	[ "$#" -gt 0 ] && lodor_prompt -t "Recent activity" -m "B to go back" "$@" >/dev/null 2>&1
}

# -- Re-pair / device options. Text entry (server URL/token) is done by editing config.json
#    on the card (no arbitrary-text keyboard on this lane); re-register fixes the common
#    missing-device_id case without any typing. ---------------------------------------------
do_repair() {
	lodor_prompt -t "Re-pair this device" -m "Choose an action" 		"Re-register this device with RomM" 		"How to change server / token"
	case $? in
		0)
			ensure_online "Lodor" || return
			ui_show "Lodor" "Re-registering with RomM..."
			OUT=$(lodor_engine --register-device "Miyoo Mini Plus (OnionOS)" 2>&1); _r=$?
			echo "$OUT" >> "$LOG"; ui_dismiss
			if [ "$_r" = 0 ]; then ui_result "Re-paired" "This device is registered with RomM.
Saves will sync under its own name."
			else ui_result "Re-pair failed" "$(diagnose "$_r")"; fi ;;
		1)
			ui_result "Change server / token" "Edit this file on the card:
App/LodorSync/data/config.json
 
Set root_uri + token (see
config.json.example), then reopen Lodor." ;;
		*) return ;;
	esac
}

# -- Download a game: pick a system, then a title; the engine fetches + hash-verifies it. ---
do_download_menu() {
	ensure_online "Lodor" || return
	# Systems = bare-tag Roms/ folders holding >=1 stub/game.
	set --; _paths=""
	for d in "$ROMS_ROOT"/*/; do
		[ -d "$d" ] || continue
		case "$(basename "$d")" in .*|*"(LODOR"*) continue ;; esac
		_first=$(find "$d" -maxdepth 1 -type f ! -name ".*" 2>/dev/null | head -1)
		[ -n "$_first" ] || continue
		_cnt=$(find "$d" -maxdepth 1 -type f ! -name ".*" 2>/dev/null | wc -l | tr -d " ")
		set -- "$@" "$(basename "$d")  ($_cnt)"
		_paths="$_paths$d
"
	done
	if [ "$#" -eq 0 ]; then
		ui_result "Download games" "No library yet.
 
Run 'Sync now' first to mirror your
RomM library, then come back."
		return
	fi
	lodor_prompt -t "Download — pick a system" "$@"; _si=$?
	[ "$_si" = 255 ] && return
	_sysdir=$(printf '%s' "$_paths" | sed -n "$((_si+1))p")
	[ -n "$_sysdir" ] || return
	# Titles in that system.
	set --; _games=""
	for f in "$_sysdir"*; do
		[ -f "$f" ] || continue
		case "$(basename "$f")" in .*) continue ;; esac
		set -- "$@" "$(basename "$f")"
		_games="$_games$f
"
	done
	if [ "$#" -eq 0 ]; then ui_result "Download games" "That system has no games."; return; fi
	lodor_prompt -t "Pick a game to download" "$@"; _gi=$?
	[ "$_gi" = 255 ] && return
	_game=$(printf '%s' "$_games" | sed -n "$((_gi+1))p")
	[ -n "$_game" ] || return
	run_with_progress "Lodor" -- --download "$_game"; _dr=$?
	if [ "$_dr" = 0 ]; then ui_result "Downloaded" "$(basename "$_game")
 
Ready to play from the Games list."
	else ui_result "Download failed" "$(diagnose "$_dr")"; fi
}

# -- About / status (local, no network). --------------------------------------------------
do_about() {
	_last=$(cat "$LASTSYNC" 2>/dev/null); [ -n "$_last" ] || _last="never"
	_games=$(find "$ROMS_ROOT" -type f ! -name ".*" 2>/dev/null | wc -l | tr -d " ")
	# Live engine version (T1.4) — no more hardcoded stamp drifting out of date.
	_ver=$(lodor_engine --version 2>/dev/null | awk '{print $2}'); [ -n "$_ver" ] || _ver=unknown
	# Parked-offline saves waiting for the daemon — surface the count so they are not invisible.
	_pend=0; [ -f "$PENDING" ] && _pend=$(wc -l < "$PENDING" 2>/dev/null | tr -d " "); [ -n "$_pend" ] || _pend=0
	ui_result "About Lodor" "RomM library sync for OnionOS
Version $_ver
 
Last sync: $_last
Games in library: $_games
Pending saves: $_pend"
}

# -- Settings helpers (T2.2): read/write the shell-owned engine overlay (settings.conf). The
#    engine only ever READS these; the shell is the single writer (set_setting, in the lib). --
get_mirror_mode() {   # own|separate|merge (default merge — the engine's own default)
	_m=$(get_setting mirror_mode)
	case "$_m" in own) echo own ;; separate) echo separate ;; *) echo merge ;; esac
}
get_fetch_covers() {  # on|off — settings.conf overrides config.json; absent everywhere = off
	_fc=$(get_setting fetch_covers)
	case "$_fc" in on) echo on; return ;; off) echo off; return ;; esac
	if grep -q '"fetch_covers"[[:space:]]*:[[:space:]]*true' "$DATA_DIR/config.json" 2>/dev/null; then
		echo on
	else
		echo off
	fi
}
do_toggle_library_mode() {   # cycle merge -> separate -> own -> merge (writes mirror_mode)
	case "$1" in
		merge)    _next=separate ;;
		separate) _next=own ;;
		*)        _next=merge ;;
	esac
	if set_setting mirror_mode "$_next"; then
		ui_result "Library mode: $_next" "Applies on your next\n\"Refresh library\"."
	else
		ui_result "Couldn't save" "Check the SD card and try again."
	fi
}
do_toggle_box_art() {   # on <-> off (writes fetch_covers)
	if [ "$1" = on ]; then _next=off; else _next=on; fi
	if set_setting fetch_covers "$_next"; then
		if [ "$_next" = on ]; then
			ui_result "Box art: on" "Box art for your whole library downloads\non the next Refresh library (can be slow)."
		else
			ui_result "Box art: off" "Only downloaded games fetch box art now.\nArt already on the card is kept."
		fi
	else
		ui_result "Couldn't save" "Check the SD card and try again."
	fi
}
do_download_bios() {   # --download-bios: BYOB firmware pull for every mapped platform (no bundled BIOS)
	ensure_online "Lodor" || return
	run_with_progress "Lodor" -- --download-bios; _r=$?
	OUT=$(cat "$LODOR_RUN_OUT" 2>/dev/null)
	if [ "$_r" = 0 ]; then
		_sum=$(echo "$OUT" | grep -i "^RESULT bios=" | head -1)
		ui_result "BIOS downloaded" "${_sum:-BIOS files are on the card.}"
	else
		ui_result "BIOS download failed" "$(diagnose "$_r")"
	fi
}

# -- Settings submenu (nested prompt): toggles + less-common actions, off the top level so the
#    primary menu stays short on the Mini. Loops until B/cancel, then returns to the top. ------
do_settings() {
	while :; do
		_lm=$(get_mirror_mode)
		_bx=$(get_fetch_covers)
		lodor_prompt -t "Settings" -m "B to go back" \
			"Library mode: $_lm" \
			"Box art: $_bx" \
			"Download BIOS" \
			"Re-pair this device" \
			"About Lodor"
		_ss=$?
		log "settings: selection=$_ss"
		case $_ss in
			0) do_toggle_library_mode "$_lm" ;;
			1) do_toggle_box_art "$_bx" ;;
			2) do_download_bios ;;
			3) do_repair ;;
			4) do_about ;;
			*) break ;;
		esac
	done
}

# -- Main options menu (OnionOS `prompt`). Mirrors the other lanes Tools menu. --------------
run_menu() {
	while :; do
		log "menu: showing options (prompt=${PROMPT:-unresolved})"
		lodor_prompt -t "Lodor" -m "RomM library sync" \
			"Sync now" \
			"Refresh library" \
			"Download a game" \
			"Pull saves from server" \
			"Recent activity" \
			"Settings ▸"
		_ms=$?
		log "menu: selection=$_ms"
		case $_ms in
			0) do_sync_now ;;
			1) do_refresh_library ;;
			2) do_download_menu ;;
			3) do_pull_saves ;;
			4) do_recent ;;
			5) do_settings ;;
			*) break ;;   # B / cancel exits the app
		esac
	done
}

# -- first-run / every-run reheal (idempotent): install launch wraps + boot daemon.
ui_show "Lodor" "Checking install..."
"$SELF_DIR/bin/lodor-seed.sh" >> "$LOG" 2>&1

# -- Hold the fleet transfer mutex fg for the App session so the background daemon yields.
wifi_acquire fg >/dev/null 2>&1 || log "transfer mutex busy at app start (proceeding; best-effort)"

# -- Show the interactive options menu (OnionOS `prompt` renders via MI-GFX; raw fb is dead
#    on the SSD202D). B on the top menu exits. Every action reports honestly via infoPanel.
#    Safety: if `prompt` is somehow absent on this card, degrade to the auto-sync-on-open
#    behaviour rather than dead-ending on a blank screen (never a worse UX than before).
prompt_available() {
	for c in "$SYSDIR/bin/prompt" "$SDCARD/.tmp_update/bin/prompt" "$APPDIR/bin/prompt"; do
		[ -x "$c" ] && return 0
	done
	command -v prompt >/dev/null 2>&1
}
ui_dismiss
if prompt_available; then
	run_menu
else
	log "prompt picker not found on card — falling back to auto-sync-on-open"
	do_sync_now
fi
exit 0
