#!/bin/sh
# lodor-launch.sh - OnionOS per-system launch wrap, installed AS Emu/<TAG>/launch.sh for
# each RetroArch system Lodor mirrors (the stock script is preserved beside it as
# launch.stock.sh).  MARKER: LODOR_ONION_LAUNCH
#
# MainUI invokes this with the ROM path as "$1" (via .tmp_update/cmd_to_run.sh). Our job,
# in order, is exactly:
#   1. stub-fetch:  a 0-byte stub means the real ROM isn't on the card yet -> bring Wi-Fi
#      up, download it, hash-verify. If it fails, DO NOT launch an empty file - return to
#      the menu honestly.
#   2. save restore (HEADLESS on OnionOS): the interactive per-game launch card (launch-card-v2,
#      lodor-wizard --launch-card) draws via raw /dev/fb0, which does NOT scan out on the
#      SSD202D Miyoo Mini under OnionOS — so it is GATED OFF on this lane. Instead we do the
#      proven SILENT --sync-save pull (newest server save wins), opportunistically (only when
#      Wi-Fi is already up; never bring the radio up just to restore a save). No card, no
#      blank screen, no hang before the game — just the headless-safe save bracket. The rich
#      interactive card returns when the mmiyoo-SDL bridge lands (separate task).
#   3. hand off to the STOCK launcher (launch.stock.sh) - it picks the core + launches
#      RetroArch, which writes the save to Saves/CurrentProfile/saves/<Core>/. We do NOT
#      reimplement launching.
#   4. push-after: if the save changed this session, push now if Wi-Fi is up, else queue.
#
# HARD RULE: launching the game is NEVER gated on sync. Every sync step is best-effort and
# bounded; if anything sync-related fails (card missing / network / timeout), the stock
# launcher still runs.

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0" 2>/dev/null || echo "$0")")" && pwd 2>/dev/null)
# The wrap lives in Emu/<TAG>/; the app lib is under App/LodorSync/. Reheal-locate the lib.
EMU_TAG=$(basename "$SELF_DIR")
LIB=""
for c in "${SDCARD:-/mnt/SDCARD}/App/LodorSync/lib/romm-sync-lib.sh" \
         /mnt/SDCARD/App/LodorSync/lib/romm-sync-lib.sh; do
	[ -f "$c" ] && { LIB="$c"; break; }
done

ROM="$1"
STOCK="$SELF_DIR/launch.stock.sh"

# If the lib is missing, we MUST still launch the game. Fall straight through to stock.
if [ -z "$LIB" ]; then
	[ -x "$STOCK" ] && exec "$STOCK" "$@"
	exit 1
fi
. "$LIB"
lodor_export_env

# Mark the in-game session so the daemon won't fight us for the radio mid-play.
echo "$$" > "$INGAME_LOCK" 2>/dev/null
trap 'ui_dismiss 2>/dev/null; rm -f "$INGAME_LOCK" 2>/dev/null' EXIT INT TERM HUP QUIT

log "launch TAG=$EMU_TAG ROM=$ROM"

# --- 1. Fetch-on-launch: a 0-byte stub means the real ROM isn't on the card yet. --------
# Feedback via OnionOS's native infoPanel (MI-GFX) — MainUI has exited and RetroArch hasn't
# started, so without it the user stares at a blank screen during the download. No raw fb.
if [ -f "$ROM" ] && [ ! -s "$ROM" ]; then
	_rname=$(basename "$ROM")
	# T2.1: a large disc image (.chd, or a disc-based-system folder) can be a
	# multi-hundred-MB first-launch download — warn the user to keep it plugged in
	# BEFORE the (now resumable, progress-barred) fetch. infoPanel --auto is a one-button
	# ack; large first launches are rare + the user is right there having just picked it.
	case "$_rname" in
		*.chd|*.CHD) _islarge=1 ;;
		*)
			case "/$ROM/" in
				*/Roms/SEGACD/*|*/Roms/PS/*|*/Roms/SATURN/*|*/Roms/DC/*) _islarge=1 ;;
				*) _islarge=0 ;;
			esac ;;
	esac
	if [ "$_islarge" = 1 ]; then
		ui_result "Large game" "$_rname\n \nFirst launch downloads over Wi-Fi.\nKeep it plugged in - this can take a while."
	fi
	phase "Downloading $_rname..."
	# T1.3: retry-with-resume. The engine resumes from a retained .tmp via HTTP Range
	# (modes.go:235 / client.go:493), so each attempt finishes strictly MORE of the file —
	# a SIGTERM-at-94% means attempt 2 completes. Re-assert Wi-Fi each pass (a mid-download
	# drop is common on the Mini) and back off quadratically (try*try*3 s). The engine-driven
	# progress bar (run_with_progress) replaces the old static "Downloading" line; the env it
	# needs (LODOR_RUN_OUT etc.) was exported by lodor_export_env above.
	_wrc=0; _try=1
	while [ "$_try" -le 3 ]; do
		wifi_bring_up; _wrc=$?
		if [ "$_wrc" = 0 ]; then
			run_with_progress "$_rname" -- --download "$ROM"
		elif [ "$_wrc" = 2 ]; then
			log "fetch-on-launch: Wi-Fi not configured in OnionOS"
			break   # no creds to retry against — fall to the honest panel below
		else
			log "fetch-on-launch attempt $_try: no network"
		fi
		[ -s "$ROM" ] && break   # real bytes on card — done
		[ "$_try" -lt 3 ] && sleep $(( _try * _try * 3 ))
		_try=$(( _try + 1 ))
	done
	if [ ! -s "$ROM" ]; then
		phase "Download failed"
		log "fetch-on-launch FAILED (rom still empty after retries) - abort launch"
		if [ "$_wrc" = 2 ]; then
			ui_result "Can't download" "$_rname\n \nWi-Fi isn't set up. Open OnionOS\nWi-Fi settings, then relaunch."
		else
			ui_result "Download failed" "$_rname\n \nCouldn't fetch it. Check Wi-Fi + your\nRomM server, then try again."
		fi
		rm -f "$INGAME_LOCK" 2>/dev/null
		exit 0
	fi
	ui_dismiss
	phase "Downloaded $_rname"
fi

# --- 2. Always-show launch card (task #80). `prompt` renders via OnionOS MI-GFX; raw /dev/fb0
# is dead on the SSD202D, so the graphical lodor-wizard card stays off — the shell card in the
# lib (lodor_launch_card) gives the SAME function: Play / Restore latest save / Restore a save
# state, probing --list-saves/--list-states and dispatching to --sync-save/--pull-state.
# ONLINE-ONLY (restore needs the server) and NON-BLOCKING (B or ~15s idle = Play); offline
# just launches. First-play (no local save) still gets a silent cloud pull inside the card.
if [ -n "$ROM" ] && wifi_is_up; then
	lodor_launch_card "$ROM"
fi

# --- 3. Hand off to OnionOS's STOCK launcher (load-bearing). ------------------------------
# Tear down any infoPanel still up (download panel) so it can't fight RetroArch for the display.
ui_dismiss
if [ -x "$STOCK" ]; then
	"$STOCK" "$@"
	rc=$?
elif [ -f "$STOCK" ]; then
	sh "$STOCK" "$@"
	rc=$?
else
	log "FATAL stock launcher not found at $STOCK"
	rc=127
fi

# --- 4. Post-game save handling. RetroArch already wrote the save to the card. If it
# CHANGED this session: push now when Wi-Fi is up, else queue for the daemon. A quit must
# never block on the radio (offline-first), so the queue is the default when dark. --------
if [ -n "$ROM" ] && [ -e "$INGAME_LOCK" ]; then
	_rb=$(basename "$ROM"); _rbne="${_rb%.*}"
	# -iname takes a GLOB: escape [ ] * ? \\ in the stem or "Zelda [v1]" never matches
	# its own save (bracket = character class) and changes are silently never pushed.
	_rbesc=$(printf %s "$_rbne" | sed "s/[][*?\\\\]/\\\\&/g")
	if find "$SAVES_ROOT" -newer "$INGAME_LOCK" \( -iname "$_rbesc.srm" -o -iname "$_rbesc.sav" -o -iname "$_rbesc.*" \) 2>/dev/null | grep -q .; then
		if wifi_is_up; then
			_out=$(lodor_engine --sync-save "$ROM" 2>&1); _src=$?
			printf '%s\n' "$_out" >> "$LOG" 2>/dev/null
			_res=$(printf '%s\n' "$_out" | grep '^RESULT ' | tail -1)
			log "save-push rc=$_src ${_res:-RESULT none} game=$(basename "$ROM")"
			[ "$_src" = 0 ] || { grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"; }
		else
			grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"
			log "save changed, offline -> queued pending"
		fi
	fi
	# STATE push (T1.1) — DECOUPLED from the save-file gate above (the moat): a quicksave-only
	# session writes NO .srm, so the save find never fires, yet a new save STATE still must go
	# up. Online: push this rom's states, then drain the pending-states queue. Offline: queue
	# instantly (WiFi-dark, never blocks a quit; the daemon drains later). Each engine call runs
	# cwd=$DATA_DIR (config.json is CWD-relative) + self-heals device via lodor_ensure_device,
	# and is bounded by lodor_timeout so a quit never blocks on the radio.
	if wifi_is_up; then
		lodor_ensure_device
		( cd "$DATA_DIR" 2>/dev/null && lodor_timeout 25 "$BIN" --push-states "$ROM" ) >> "$LOG" 2>&1 \
			|| log "push-states nonzero (offline auto-queues) game=$(basename "$ROM")"
		( cd "$DATA_DIR" 2>/dev/null && lodor_timeout 25 "$BIN" --push-pending-states ) >> "$LOG" 2>&1 || true
	else
		( cd "$DATA_DIR" 2>/dev/null && lodor_timeout 10 "$BIN" --queue-state "$ROM" ) >> "$LOG" 2>&1 || true
		log "state offline -> queued for daemon game=$(basename "$ROM")"
	fi
fi

rm -f "$INGAME_LOCK" 2>/dev/null
exit "$rc"
