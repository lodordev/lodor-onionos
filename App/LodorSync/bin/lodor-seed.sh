#!/bin/sh
# lodor-seed.sh - (re)install the OnionOS launch-interception wraps + the boot daemon hook.
# Idempotent; safe to run on every app launch and at boot. Detect-and-reheal: OnionOS
# restores stock Emu/<TAG>/ files on OS update, so we re-wrap every run.  MARKER: LODOR_SEED
#
# OnionOS has NO supported pre-launch hook (no override dir like muOS). The only no-fork
# seam is the per-system Emu/<TAG>/launch.sh, which MainUI invokes (via cmd_to_run.sh) with
# the ROM path as $1. We install our wrap by:
#   - moving the stock launch.sh aside to launch.stock.sh (ONCE, only if not already done),
#   - dropping our lodor-launch.sh in as launch.sh.
# Our wrap does stub-fetch -> opportunistic pull -> exec launch.stock.sh (stock launcher,
# correct core) -> push/queue. We only wrap RetroArch systems (is_retroarch_emu); standalone
# emulators are left untouched so their launch never breaks.
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/../lib/romm-sync-lib.sh"
lodor_export_env

WRAP_SRC="$APPDIR/bin/lodor-launch.sh"
MARK="MARKER: LODOR_ONION_LAUNCH"

is_our_wrap() { [ -f "$1" ] && grep -q "$MARK" "$1" 2>/dev/null; }

wrap_one() {
	_tag="$1"
	_dir="$EMU_ROOT/$_tag"
	_live="$_dir/launch.sh"
	_stock="$_dir/launch.stock.sh"
	[ -d "$_dir" ] || return 1

	# Fresh or OS-update-restored stock launch.sh sitting in place (not ours): preserve it.
	# (If _live is ALREADY our wrap we fall straight through and re-copy the latest wrap
	# body below — so engine/wrap updates propagate without leaving a stale wrap behind.)
	if [ -f "$_live" ] && ! is_our_wrap "$_live"; then
		# Don't clobber a real stock we haven't saved yet.
		[ -f "$_stock" ] || cp -f "$_live" "$_stock" 2>/dev/null
	fi
	# Only wrap RetroArch systems; leave standalone emulators alone.
	is_retroarch_emu "$_tag" || { return 1; }
	# Install the wrap.
	cp -f "$WRAP_SRC" "$_live" 2>/dev/null && chmod +x "$_live" 2>/dev/null || return 1
	return 0
}

wrapped=0; skipped=0
# Only consider systems we actually mirror (a Roms/<TAG> folder exists) AND that OnionOS
# has an Emu/<TAG> for. This keeps us off systems the user manages by hand.
if [ -d "$ROMS_ROOT" ]; then
	for rd in "$ROMS_ROOT"/*/; do
		[ -d "$rd" ] || continue
		tag=$(basename "$rd")
		if wrap_one "$tag"; then
			wrapped=$((wrapped + 1))
		else
			skipped=$((skipped + 1))
		fi
	done
fi

# --- Boot daemon autostart: OnionOS runs every *.sh in .tmp_update/startup/ at boot. -----
# Write only if absent so we never duplicate / double-start. Deleting it disables autostart;
# this re-heals it. Background the daemon + return fast so boot isn't delayed.
mkdir -p "$SYSDIR/startup" 2>/dev/null
BOOT_HOOK="$SYSDIR/startup/lodor.sh"
if [ ! -f "$BOOT_HOOK" ]; then
	cat > "$BOOT_HOOK" <<EOF
#!/bin/sh
# Lodor RomM Sync boot hook (re-healed by lodor-seed.sh; delete to disable). MARKER: LODOR_BOOT
"$APPDIR/bin/lodor-seed.sh" >/dev/null 2>&1     # re-wrap Emu launch.sh after any OS update
"$APPDIR/bin/romm-syncd" &                       # start the charging-gated save daemon
EOF
	chmod +x "$BOOT_HOOK" 2>/dev/null
fi

# --- Shutdown hook: OnionOS runs .tmp_update/checkoff/*.sh on power-off. Flush the queue
# is NOT safe here (no radio at shutdown); we only ensure the radio is left off + lock reaped.
mkdir -p "$SYSDIR/checkoff" 2>/dev/null
OFF_HOOK="$SYSDIR/checkoff/lodor.sh"
if [ ! -f "$OFF_HOOK" ]; then
	cat > "$OFF_HOOK" <<EOF
#!/bin/sh
# Lodor shutdown hook. MARKER: LODOR_CHECKOFF
rm -f /tmp/romm-in-game 2>/dev/null
EOF
	chmod +x "$OFF_HOOK" 2>/dev/null
fi

log "seed: wrapped=$wrapped skipped=$skipped (RetroArch Emu/<TAG>/launch.sh wrapped; standalone untouched)"
echo "SEED wrapped=$wrapped skipped=$skipped"
