#!/bin/sh
# launch.sh - the "Lodor Sync" entry under the OnionOS Apps tab. MainUI runs this when the
# app is selected (CWD = this folder).  MARKER: LODOR_APP
#
# A REAL on-screen menu, drawn by bin/lodor-menu - a CGO-free /dev/fb0 + evdev renderer
# (source: integrations/onionos/menu). This REPLACES the old console-only flow: OnionOS
# MainUI shows no stdout, so the echo+keypress script left a blank screen that read as a
# crash. Every screen the user sees now comes from lodor-menu writing the framebuffer.
#
# Menu (mirrors the unified Lodor menu):
#   Sync now           : flush pending saves (--push-pending) + mirror the library
#   Refresh library    : re-mirror catalog (--mirror-catalog) + collections (--mirror-collections)
#   Library mode       : toggle coexist Own <-> Separate (offline-safe; engine reads settings.conf)
#   Settings / status  : connected-as (server + device), library mode, last sync
#
# Host rendering ONLY. ALL RomM logic stays in the engine, reached through the lib's
# lodor_engine / wifi_bring_up / set_clock. HONESTY (feedback_no_fake_ui_state): a step is
# shown "done" only after the engine actually returned 0; failures show the SPECIFIC real
# cause; never fake forward-progress. (RA tuning + box-art are separate builds - not here.)
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LODOR_APPDIR="$SELF_DIR"
. "$SELF_DIR/lib/romm-sync-lib.sh"
lodor_export_env

MENU="$SELF_DIR/bin/lodor-menu"
SETTINGS="$DATA_DIR/settings.conf"        # engine reads this from its CWD ($DATA_DIR)
LASTSYNC="$DATA_DIR/last-sync.txt"

# -- UI helpers (host rendering only; the shell decides WHAT to show, the engine decides if true)
ui_working() {   # title body : draw + return immediately (stays up while a blocking call runs)
	[ -x "$MENU" ] && "$MENU" show --title "$1" --body "$2" --tone info >/dev/null 2>&1
	log "working: $1 - $2"
}
ui_result() {    # title body tone : draw + wait for a button
	[ -x "$MENU" ] && "$MENU" show --title "$1" --body "$2" --tone "$3" --wait >/dev/null 2>&1
	log "result($3): $1 - $2"
}

# -- coexist (mirror_mode). Written to settings.conf ONLY, never config.json, so a UI toggle
#    can never corrupt the token. On OnionOS "own" = card IS the RomM library (bare filenames);
#    "separate" = RomM files get a " (RomM)" suffix so they coexist with the user's own games.
get_mirror_mode() {
	_mm=own
	[ -f "$SETTINGS" ] && _mm="$(sed -n 's/^mirror_mode=//p' "$SETTINGS" 2>/dev/null | head -1)"
	case "$_mm" in separate) echo separate ;; merge) echo merge ;; *) echo own ;; esac
}
set_mirror_mode() {
	_new="$1"; _tmp="$SETTINGS.tmp.$$"
	{ [ -f "$SETTINGS" ] && grep -v '^mirror_mode=' "$SETTINGS" 2>/dev/null; echo "mirror_mode=$_new"; } > "$_tmp" 2>/dev/null \
		&& mv -f "$_tmp" "$SETTINGS" 2>/dev/null
	rm -f "$_tmp" 2>/dev/null
	[ "$(get_mirror_mode)" = "$_new" ]
}
mode_label() {
	case "$1" in
		separate) echo "Separate - coexist with my games" ;;
		merge)    echo "Merge (in testing)" ;;
		*)        echo "Own - card is the RomM library" ;;
	esac
}

# -- config.json readers (runtime only; never logged/committed)
cfg_host() { sed -n 's#.*"root_uri"[^"]*"https\{0,1\}://\([^/"]*\).*#\1#p' "$DATA_DIR/config.json" 2>/dev/null | head -1; }
cfg_device() { sed -n 's#.*"device_name"[^"]*"\([^"]*\).*#\1#p' "$DATA_DIR/config.json" 2>/dev/null | head -1; }

note_synced() { date +'%F %T' > "$LASTSYNC" 2>/dev/null; }

# -- diagnose a non-zero engine rc into an HONEST cause line (cheap local preconditions first).
diagnose() {
	if   ! creds_present; then echo "Not configured - add your RomM server + token to data/config.json, then reopen."
	elif ! wifi_is_up;    then echo "Wi-Fi not connected - $(cat "$PHASE" 2>/dev/null). Enable Wi-Fi in OnionOS, then retry."
	elif [ "${1:-1}" = 3 ]; then echo "Couldn't reach your RomM server - check the server/token (logs: data/romm.log)."
	else                       echo "Sync failed (rc=${1:-?}) - see data/romm.log."
	fi
}

# -- ensure Wi-Fi + clock; on failure leaves an honest result screen and returns 1.
ensure_online() {  # title
	if ! creds_present; then
		ui_result "$1" "Not configured.\n\nAdd your RomM server + pairing token to:\n  App/LodorSync/data/config.json\n(see config.json.example), then reopen Lodor Sync." bad
		return 1
	fi
	ui_working "$1" "Connecting to Wi-Fi..."
	if ! wifi_bring_up; then
		ui_result "$1" "Wi-Fi: $(cat "$PHASE" 2>/dev/null)\n\nEnable Wi-Fi in OnionOS, then reopen Lodor Sync." bad
		return 1
	fi
	return 0
}

# -- actions ---------------------------------------------------------------------------------
do_sync_now() {     # push-pending + mirror
	ensure_online "Sync now" || return
	_rc=0
	if [ -s "$PENDING" ]; then
		ui_working "Sync now" "Flushing pending saves..."
		lodor_engine --push-pending >> "$LOG" 2>&1 || _rc=$?
	fi
	ui_working "Sync now" "Mirroring your RomM library..."
	MIRROR=$(lodor_engine --mirror-catalog 2>&1); _r2=$?; echo "$MIRROR" >> "$LOG"
	[ "$_r2" -gt "$_rc" ] && _rc=$_r2
	if [ "$_rc" = 0 ]; then
		note_synced
		_sum=$(echo "$MIRROR" | grep -i "^MIRROR" | head -1)
		ui_result "Sync now" "Sync complete.\n${_sum:-Library mirrored.}\n\nRefresh your games list to see new titles." good
	else
		ui_result "Sync now" "$(diagnose "$_rc")" bad
	fi
}

do_refresh() {      # mirror-catalog + mirror-collections
	ensure_online "Refresh library" || return
	ui_working "Refresh library" "Mirroring catalog..."
	MIRROR=$(lodor_engine --mirror-catalog 2>&1); _r1=$?; echo "$MIRROR" >> "$LOG"
	ui_working "Refresh library" "Mirroring collections..."
	lodor_engine --mirror-collections >> "$LOG" 2>&1; _r2=$?
	_rc=0; for _r in $_r1 $_r2; do [ "$_r" -gt "$_rc" ] && _rc=$_r; done
	if [ "$_rc" = 0 ]; then
		note_synced
		_sum=$(echo "$MIRROR" | grep -i "^MIRROR" | head -1)
		ui_result "Refresh library" "Library refreshed.\n${_sum:-Catalog + collections mirrored.}\n\nRefresh your games list to see changes." good
	else
		ui_result "Refresh library" "$(diagnose "$_rc")" bad
	fi
}

do_coexist() {      # offline-safe Own <-> Separate
	_cur="$(get_mirror_mode)"
	case "$_cur" in own) _next=separate ;; *) _next=own ;; esac
	if set_mirror_mode "$_next"; then
		ui_result "Library mode" "Now: $(mode_label "$_next")\n\nRun Refresh library to re-lay your games under the new mode." good
	else
		ui_result "Library mode" "Couldn't save the setting - check the SD card (data/ must be writable)." bad
	fi
}

do_settings() {
	_host="$(cfg_host)"; _dev="$(cfg_device)"
	_mode="$(mode_label "$(get_mirror_mode)")"
	_last="$(cat "$LASTSYNC" 2>/dev/null)"; [ -n "$_last" ] || _last="never"
	if creds_present; then _conn="configured"; else _conn="NOT configured (add token to data/config.json)"; fi
	ui_result "Settings / status" "Server: ${_host:-not set}\nDevice: ${_dev:-not set}\nLibrary mode: ${_mode}\nLast sync: ${_last}\nStatus: ${_conn}" info
}

# -- menu loop -------------------------------------------------------------------------------
run_menu() {
	while :; do
		_mode="$(get_mirror_mode)"
		_clabel="Library mode: $(mode_label "$_mode")"
		if creds_present; then
			_h="$(cfg_host)"; _l="$(cat "$LASTSYNC" 2>/dev/null)"; [ -n "$_l" ] || _l="never"
			_status="Connected: ${_h:-set}   Last sync: ${_l}"
		else
			_status="Not configured - open Settings / status"
		fi
		_idx=$("$MENU" menu --title "Lodor" --status "$_status" -- \
			"Sync now" "Refresh library" "$_clabel" "Settings / status")
		_rc=$?
		case "$_rc" in
			0) : ;;                # selection index in $_idx
			10) return 0 ;;        # Back (B) -> clean app exit
			*) return "$_rc" ;;    # render/input failure -> caller degrades
		esac
		case "$_idx" in
			0) do_sync_now ;;
			1) do_refresh ;;
			2) do_coexist ;;
			3) do_settings ;;
			*) return 0 ;;
		esac
	done
}

# -- first-run / every-run reheal (idempotent): install launch wraps + boot daemon.
ui_working "Lodor" "Checking install..."
"$SELF_DIR/bin/lodor-seed.sh" >> "$LOG" 2>&1

# -- drive the menu; degrade HONESTLY if the renderer can't draw/read (never a silent blank).
if [ -x "$MENU" ]; then
	run_menu; mrc=$?
	if [ "$mrc" != 0 ]; then
		log "lodor-menu render/input failed (rc=$mrc) - degrading to one-shot Sync now"
		do_sync_now
	fi
else
	log "lodor-menu binary missing - degrading to one-shot Sync now"
	do_sync_now
fi
exit 0
