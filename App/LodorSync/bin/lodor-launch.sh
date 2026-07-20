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
#   2. pull-before: OPPORTUNISTIC only (never bring the radio up just to pull) - newest
#      server save wins.
#   3. hand off to the STOCK launcher (launch.stock.sh) - it picks the core + launches
#      RetroArch, which writes the save to Saves/CurrentProfile/saves/<Core>/. We do NOT
#      reimplement launching.
#   4. push-after: if the save changed this session, push now if Wi-Fi is up, else queue.
#
# HARD RULE: launching the game is NEVER gated on sync. Every sync step is best-effort and
# bounded; if anything sync-related fails, the stock launcher still runs.

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
trap 'rm -f "$INGAME_LOCK" 2>/dev/null' EXIT INT TERM HUP QUIT

log "launch TAG=$EMU_TAG ROM=$ROM"

# --- 1. Fetch-on-launch: a 0-byte stub means the real ROM isn't on the card yet. --------
if [ -f "$ROM" ] && [ ! -s "$ROM" ]; then
	phase "Downloading $(basename "$ROM")..."
	if wifi_bring_up; then
		lodor_engine --download "$ROM" >> "$LOG" 2>&1
	else
		log "fetch-on-launch: no network"
	fi
	if [ ! -s "$ROM" ]; then
		phase "Download failed - returning to menu"
		log "fetch-on-launch FAILED (rom still empty) - abort launch"
		rm -f "$INGAME_LOCK" 2>/dev/null
		exit 0
	fi
	phase "Downloaded $(basename "$ROM")"
fi

# --- 2. Save pull-before: OPPORTUNISTIC. Never bring Wi-Fi up just to pull. Bounded. -----
# (No core context here - the engine pulls to the system's default-core folder; the
# around-session push + newest-wins converges any non-default-core case.)
if [ -n "$ROM" ] && wifi_is_up; then
	if command -v timeout >/dev/null 2>&1; then
		_out=$( ( cd "$DATA_DIR" && timeout 25 "$BIN" --sync-save "$ROM" ) 2>&1 ); _src=$?
	else
		_out=$(lodor_engine --sync-save "$ROM" 2>&1); _src=$?
	fi
	printf '%s\n' "$_out" >> "$LOG" 2>/dev/null
	# One timestamped decision line (the nextui slog convention): the engine's RESULT
	# pulled=/pushed=/ghosts=/reason= token is what a field diagnosis reads first —
	# without it "nothing to pull" and "server unreachable" are indistinguishable.
	_res=$(printf '%s\n' "$_out" | grep '^RESULT ' | tail -1)
	log "save-pull rc=$_src ${_res:-RESULT none} game=$(basename "$ROM")"
fi

# --- 3. Hand off to OnionOS's STOCK launcher (load-bearing). ------------------------------
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
	if find "$SAVES_ROOT" -newer "$INGAME_LOCK" \( -iname "$_rbne.srm" -o -iname "$_rbne.sav" -o -iname "$_rbne.*" \) 2>/dev/null | grep -q .; then
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
fi

rm -f "$INGAME_LOCK" 2>/dev/null
exit "$rc"
