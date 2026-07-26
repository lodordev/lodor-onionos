#!/bin/bash
# onion-sim.sh — off-device (x86) simulator for the OnionOS App/LodorSync shell flows.
# Modeled on integrations/nextui/test/wizard-sim.sh (the proven harness pattern).
#
# Runs the REAL launch.sh / bin/lodor-launch.sh / bin/lodor-seed.sh / bin/romm-syncd +
# lib/romm-sync-lib.sh headlessly inside a throwaway fake-SD-card sandbox:
#   sandbox/sdcard/App/LodorSync/          <- real App scripts + lib, STUB engine at the
#                                             exact path the lib resolves ($APPDIR/lodor-sync)
#   sandbox/sdcard/.tmp_update/bin/        <- STUB `prompt` + `infoPanel` (the OnionOS MI-GFX
#                                             UI binaries the lib resolves at $SYSDIR/bin)
#   sandbox/sdcard/Emu/<TAG>/              <- for `invoke wrap`: the REAL bin/lodor-launch.sh
#                                             installed as launch.sh + a RECORDER stock
#                                             launcher (launch.stock.sh) that traces STOCK
#   PATH-shadowed: sleep (time compression, SCALED: N -> N*LODOR_SIM_TICK so relative delays
#                  keep their ordering — the lc_prompt idle watchdog vs. the prompt answer),
#                  cat + ip (ONLY to script the wlan0 probes: the onion lib has no
#                  LODOR_TEST_LIB seam, so wifi_is_up's /sys/class/net/wlan0/operstate read
#                  and `ip addr show wlan0` are intercepted; everything else passes through)
#
# Every stub reads scripted behavior from per-channel queues built from a .scn file
# (sticky-last-line FIFO — see stubs/simq). Every run is wrapped in `timeout`, so a stuck
# interaction loop FAILS as TIMEOUT instead of hanging CI.
#
# HARNESS INVARIANT (auto-checked, no directive needed): every engine invocation must run
# with cwd == LODOR_PAK_DIR (the data dir — config.json is CWD-relative) and with
# LODOR_PAK_DIR + SSL_CERT_FILE exported. The engine stub tags violations BADCWD /
# NOPAKDIR / NOSSL in the trace and the harness fails the scenario on any of them.
#
# NOTE: the onion lib pins several /tmp names (romm-phase, romm-in-game, romm-wifi.lock,
# lodor-lc-states.*) with no env override, so scenarios must run SEQUENTIALLY (run-all.sh
# does); the harness clears those names before each run.
#
# Usage: onion-sim.sh <scenario.scn> [--keep]
# Exit:  0 scenario passed, 1 failed (reasons on stdout), 2 harness/usage error.
#
# Scenario directives (one per line; '#' comments):
#   desc <text>                        human description
#   timeout <secs>                     real-time budget (default 30)
#   invoke app|wrap|seed|seed2|syncd   what to run (default wrap):
#                                      app   = App/LodorSync/launch.sh (the Apps-tab entry;
#                                              CWD = the app folder, MainUI's contract)
#                                      wrap  = Emu/<TAG>/launch.sh '<SD>/<romarg>' (the REAL
#                                              bin/lodor-launch.sh staged as the wrap, with a
#                                              recorder launch.stock.sh — MainUI's launch path)
#                                      seed  = bin/lodor-seed.sh (wrap installer / boot heal)
#                                      seed2 = seed run twice (idempotency)
#                                      syncd = bin/romm-syncd (charging-gated daemon;
#                                              ROMM_SYNC_INTERVAL=0, bounded by timeout —
#                                              daemon scenarios expect_exit 124; runs under
#                                              unshare -m with a bind-mounted fake
#                                              /sys/class/power_supply for `charging`)
#   tag <TAG>                          Emu tag for wrap staging (default GBA)
#   romarg <sd-relative-path>          ROM path for `invoke wrap` (default Roms/GBA/Zelda.gba)
#   wifi up|down                       scripted wlan0 state (default down)
#   charging on|off                    syncd: fake power_supply status Charging vs. empty
#                                      (default off; needs root + unshare -m)
#   ingame                             live-pid /tmp/romm-in-game lock (daemon in-game gate)
#   holdmutex                          live-owner /tmp/romm-wifi.lock (daemon mutex-busy gate)
#   config none|token|paired           data/config.json seed (token = creds but NO device_name,
#                                      drives lodor_ensure_device; paired = token + device_name)
#   pending <sd-relative-rom-path>     append that ROM's absolute path to pending-saves.txt
#   emu <TAG> ra|standalone            stage a STOCK Emu/<TAG>/launch.sh recorder for `invoke
#                                      seed` (ra = mentions retroarch, standalone = does not)
#   stockwrites <sd-relative-path>     the recorder stock launcher writes this file when run
#                                      (models RetroArch writing a save)
#   stockrc <n>                        recorder stock launcher exit code (default 0)
#   sdfile <sd-relative-path>          create a 0-byte file (a Lodor stub) on the fake card
#   sdfile+ <sd-relative-path>         create a real (non-empty) file on the fake card
#   sdtext <rel-path>TAB<content>      create a card file with scripted content (%b-expanded)
#   pick <n|255|hang>                  queue a `prompt` answer (exit-code selection contract;
#                                      hang = never returns, exercises the idle watchdog)
#   engine <rc>|<stdout>               queue an engine result (%b-expanded: \t \n allowed)
#   no-prompt                          remove the prompt stub (prompt-missing fallback path)
#   expect_exit <n>                    invoked script must exit n (124 = harness timeout)
#   expect_timeout                     the run was ENDED BY the harness timeout (124/137) —
#                                      the by-design bound for the forever-looping daemon
#                                      (its TERM trap cleans up but does not exit, so the
#                                      -k KILL is what actually stops it)
#   expect_config_has <substr>         data/config.json contains substring
#   expect_config_lacks <substr>       data/config.json missing OR lacks substring
#   expect_trace <substr>              sim/trace.log contains substring (stub calls)
#   expect_trace_absent <substr>       sim/trace.log lacks substring
#   expect_log <substr>                data/romm.log contains substring (the lib's log())
#   expect_log_absent <substr>         data/romm.log lacks substring
#   expect_file <sd-relative-path>     file exists under the fake SD card
#   expect_file_absent <sd-rel-path>   file does NOT exist under the fake SD card
#   expect_file_empty <sd-rel-path>    file exists AND is 0 bytes (an intact Lodor stub)
#   expect_file_has <rel-path> <substr>    (TAB-separate the two when the path has spaces)
#   expect_file_lacks <rel-path> <substr>  file missing OR lacks substring
#   expect_file_lines <rel-path> <n>   file has exactly n non-blank lines
#   expect_tmp_lines <abs-path> <n>    a fixed-/tmp artifact has exactly n non-blank lines
#                                      (the lodor-lc-states.* parallel files)
set -u

SCN="${1:-}"
KEEP="${2:-}"
[ -f "$SCN" ] || { echo "usage: onion-sim.sh <scenario.scn> [--keep]" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
APPSRC="${LODOR_APP_SRC:-$HERE/../App/LodorSync}"
[ -f "$APPSRC/launch.sh" ] || { echo "FATAL: App source not found at $APPSRC" >&2; exit 2; }

NAME="$(basename "$SCN" .scn)"
ROOT="$(mktemp -d "/tmp/lodor-onionsim.$NAME.XXXXXX")"
SD="$ROOT/sdcard"
APP="$SD/App/LodorSync"
DATA="$APP/data"
SYSB="$SD/.tmp_update/bin"
SIM="$ROOT/sim"
BIN="$ROOT/bin"
mkdir -p "$APP/bin" "$APP/lib" "$APP/certs" "$DATA" "$SYSB" "$SIM/q" "$BIN"

# ---- lay down the REAL App scripts ----
cp "$APPSRC/launch.sh" "$APP/launch.sh"
cp "$APPSRC/lib/romm-sync-lib.sh" "$APP/lib/romm-sync-lib.sh"
cp "$APPSRC/bin/lodor-launch.sh" "$APP/bin/lodor-launch.sh"
cp "$APPSRC/bin/lodor-seed.sh"   "$APP/bin/lodor-seed.sh"
cp "$APPSRC/bin/romm-syncd"      "$APP/bin/romm-syncd"
printf 'STUBCERT\n' > "$APP/certs/ca-certificates.crt"   # so lodor_export_env pins SSL_CERT_FILE

# ---- stubs at the exact paths the lib resolves ----
cp "$HERE/stubs/lodor-sync" "$APP/lodor-sync"            # $BIN in the lib
cp "$HERE/stubs/prompt"     "$SYSB/prompt"               # $SYSDIR/bin/prompt
cp "$HERE/stubs/infoPanel"  "$SYSB/infoPanel"            # $SYSDIR/bin/infoPanel
for s in simq sleep cat ip; do cp "$HERE/stubs/$s" "$BIN/$s"; done
chmod +x "$APP"/bin/* "$APP/launch.sh" "$APP/lodor-sync" "$SYSB"/* "$BIN"/*

# ---- recorder stock launcher (traces STOCK + models RetroArch writing a save) ----
mk_recorder() {  # <dest> <ra|standalone>
	if [ "$2" = ra ]; then
		_ref="# stock OnionOS launcher: RetroArch handoff (.retroarch)"
	else
		_ref="# stock OnionOS launcher: standalone emulator"
	fi
	cat > "$1" <<REC
#!/bin/sh
$_ref
echo "STOCK \$(basename \$(dirname "\$0")) rom='\$1'" >> "\${LODOR_SIM_DIR:?}/trace.log"
if [ -n "\${LODOR_STOCK_WRITES:-}" ]; then
	mkdir -p "\$(dirname "\${SDCARD:?}/\$LODOR_STOCK_WRITES")" 2>/dev/null
	printf 'SAVEBYTES\n' > "\$SDCARD/\$LODOR_STOCK_WRITES"
fi
exit \${LODOR_STOCK_RC:-0}
REC
	chmod +x "$1"
}

seed_config() {
	case "$1" in
		none) rm -f "$DATA/config.json" ;;
		token)
			cat > "$DATA/config.json" <<'EOF'
{
  "hosts": [
    {
      "root_uri": "https://seed.example.com",
      "token": "stub-token",
      "stub": true
    }
  ]
}
EOF
			;;
		paired)
			cat > "$DATA/config.json" <<'EOF'
{
  "hosts": [
    {
      "root_uri": "https://seed.example.com",
      "device_name": "stub-device",
      "token": "stub-token",
      "stub": true
    }
  ]
}
EOF
			;;
		*) echo "FATAL: unknown config seed '$1'" >&2; exit 2 ;;
	esac
}

# ---- defaults ----
TMO=30
DESC=""
INVOKE="wrap"
TAG="GBA"
ROMARG="Roms/GBA/Zelda.gba"
TERMSIG=""
CHARGING="off"
STOCK_WRITES=""
STOCK_RC=0
INGAME=0
HOLDMUTEX=0
echo down > "$SIM/wifi"
EXPECTS="$ROOT/expects"
: > "$EXPECTS"

# ---- parse the scenario ----
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
	lineno=$((lineno + 1))
	line="${raw%%$'\r'}"
	case "$line" in ''|'#'*) continue ;; esac
	cmd="${line%% *}"
	arg="${line#* }"; [ "$arg" = "$line" ] && arg=""
	case "$cmd" in
		desc)      DESC="$arg" ;;
		timeout)   TMO="$arg" ;;
		invoke)
			case "$arg" in
				app|wrap|seed|seed2|syncd) INVOKE="$arg" ;;
				*) echo "FATAL: $SCN:$lineno unknown invoke '$arg'" >&2; exit 2 ;;
			esac ;;
		tag)       TAG="$arg" ;;
		romarg)    ROMARG="$arg" ;;
		termsig)   TERMSIG="$arg" ;;
		wifi)      echo "$arg" > "$SIM/wifi" ;;
		charging)  CHARGING="$arg" ;;
		ingame)    INGAME=1 ;;
		holdmutex) HOLDMUTEX=1 ;;
		config)    seed_config "$arg" ;;
		pending)   echo "$SD/$arg" >> "$DATA/pending-saves.txt" ;;
		emu)
			_et="${arg%% *}"; _ek="${arg#* }"
			mkdir -p "$SD/Emu/$_et"
			mk_recorder "$SD/Emu/$_et/launch.sh" "$_ek" ;;
		stockwrites) STOCK_WRITES="$arg" ;;
		stockrc)   STOCK_RC="$arg" ;;
		sdfile)    mkdir -p "$SD/$(dirname "$arg")"; : > "$SD/$arg" ;;
		sdfile+)   mkdir -p "$SD/$(dirname "$arg")"; printf 'REALBYTES\n' > "$SD/$arg" ;;
		sdtext)
			_st="$(printf '\t')"
			_sp="${arg%%"$_st"*}"; _sc="${arg#*"$_st"}"
			mkdir -p "$SD/$(dirname "$_sp")"; printf '%b' "$_sc" > "$SD/$_sp" ;;
		pick)      printf '%s\n' "$arg" >> "$SIM/q/prompt.q" ;;
		engine)    printf '%s\n' "$arg" >> "$SIM/q/engine.q" ;;
		no-prompt) rm -f "$SYSB/prompt" ;;
		expect_*)  printf '%s\n' "$line" >> "$EXPECTS" ;;
		*) echo "FATAL: $SCN:$lineno unknown directive '$cmd'" >&2; exit 2 ;;
	esac
done < "$SCN"

# ---- clear the lib's fixed-/tmp names (no env override on this lane) ----
rm -rf /tmp/romm-phase /tmp/dl-progress /tmp/romm-in-game /tmp/romm-wifi.lock \
       /tmp/lodor-lc-states.disp /tmp/lodor-lc-states.ids /tmp/lodor-lc-states.slots \
       /tmp/lodor-lc-states.disp.news /tmp/dismiss_info_panel 2>/dev/null

# ---- live-pid props (in-game lock / held mutex) ----
LIVEPID=""
if [ "$INGAME" = 1 ] || [ "$HOLDMUTEX" = 1 ]; then
	/bin/sleep 300 & LIVEPID=$!
fi
[ "$INGAME" = 1 ] && echo "$LIVEPID" > /tmp/romm-in-game
if [ "$HOLDMUTEX" = 1 ]; then
	mkdir /tmp/romm-wifi.lock
	echo "$LIVEPID" > /tmp/romm-wifi.lock/owner
	date +%s > /tmp/romm-wifi.lock/ts
fi

# ---- run ----
export LODOR_SIM_DIR="$SIM"
export LODOR_SIM_TICK="${LODOR_SIM_TICK:-0.02}"
export SDCARD="$SD"
export PATH="$BIN:$PATH"
export LODOR_STOCK_WRITES="$STOCK_WRITES"
export LODOR_STOCK_RC="$STOCK_RC"

case "$INVOKE" in
	wrap)
		# MainUI's launch contract: Emu/<TAG>/launch.sh '<rom path>'. Stage the REAL wrap +
		# a recorder stock beside it (the shipped-card layout lodor-seed.sh produces).
		mkdir -p "$SD/Emu/$TAG"
		cp "$APP/bin/lodor-launch.sh" "$SD/Emu/$TAG/launch.sh"
		chmod +x "$SD/Emu/$TAG/launch.sh"
		mk_recorder "$SD/Emu/$TAG/launch.stock.sh" ra
		( timeout -k 5 "$TMO" sh "$SD/Emu/$TAG/launch.sh" "$SD/$ROMARG" \
			> "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
	app)
		# MainUI runs an App's launch.sh with CWD = the app folder.
		( cd "$APP" && timeout -k 5 "$TMO" sh "$APP/launch.sh" > "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
	seed)
		( timeout -k 5 "$TMO" sh "$APP/bin/lodor-seed.sh" > "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
	seed2)
		( timeout -k 5 "$TMO" sh "$APP/bin/lodor-seed.sh" > "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		( timeout -k 5 "$TMO" sh "$APP/bin/lodor-seed.sh" >> "$ROOT/stdout.log" 2>&1 ) 2>/dev/null
		rc=$? ;;
	syncd)
		# The daemon loops forever by design: bound it with timeout (scenarios expect_exit 124)
		# and run it in a PRIVATE mount namespace with a fake /sys/class/power_supply bound
		# over the real one — `charging on` stages a Charging node, `off` an empty dir — so
		# the charging gate is scripted, not the CI host's power state. Needs root; if
		# unshare can't operate here the scenario fails loudly rather than lying.
		FAKEPS="$ROOT/fakeps"
		mkdir -p "$FAKEPS"
		if [ "$CHARGING" = on ]; then
			mkdir -p "$FAKEPS/axp0"
			echo "Charging" > "$FAKEPS/axp0/status"
		fi
		if ! unshare -m true 2>/dev/null; then
			echo "FAIL  $NAME — unshare -m unavailable (syncd scenarios need root)"; exit 1
		fi
		if [ -n "$TERMSIG" ]; then
			# termsig <seconds>: send SIGTERM after N real seconds and expect the daemon to
			# EXIT (trap exits with 143 since the 2026-07-22 fix — a signal trap that does
			# not exit lets the loop continue with its own gates opened, found live).
			env ROMM_SYNC_INTERVAL=0 \
				unshare -m sh -c "mount --bind '$FAKEPS' /sys/class/power_supply && exec sh '$APP/bin/romm-syncd'" \
				> "$ROOT/stdout.log" 2>&1 &
			_dpid=$!
			/bin/sleep "$TERMSIG"   # real seconds (not sim-ticks): signal timing is wall-clock
			kill -TERM "$_dpid" 2>/dev/null
			_g=0; while kill -0 "$_dpid" 2>/dev/null; do
				_g=$((_g+1)); [ "$_g" -gt $(( TMO * 10 )) ] && { kill -KILL "$_dpid" 2>/dev/null; break; }
				/bin/sleep 0.1
			done
			wait "$_dpid" 2>/dev/null
			rc=$?
		else
			# Hard KILL at the bound: daemon scenarios are bounded by design (the loop runs
			# forever); expect_timeout accepts the resulting 137.
			timeout -s KILL "$TMO" env ROMM_SYNC_INTERVAL=0 \
				unshare -m sh -c "mount --bind '$FAKEPS' /sys/class/power_supply && exec sh '$APP/bin/romm-syncd'" \
				> "$ROOT/stdout.log" 2>&1 &
			wait $! 2>/dev/null
			rc=$?
		fi ;;
esac
# reap orphans from this sandbox + the live-pid prop
pkill -f "$ROOT" 2>/dev/null
[ -n "$LIVEPID" ] && kill "$LIVEPID" 2>/dev/null
/bin/sleep 0.1

# ---- evaluate expectations ----
fails=0
fail() { echo "  FAIL: $1"; fails=$((fails + 1)); }
CFG="$DATA/config.json"
TRACE="$SIM/trace.log"
APPLOG="$DATA/romm.log"

# Harness invariant: every engine call carried the right cwd + env (see header).
for bad in BADCWD NOPAKDIR NOSSL; do
	if grep -q "$bad" "$TRACE" 2>/dev/null; then
		fail "engine env drift: $bad in trace ($(grep -m1 "$bad" "$TRACE"))"
	fi
done

while IFS= read -r ex; do
	ecmd="${ex%% *}"
	earg="${ex#* }"; [ "$earg" = "$ex" ] && earg=""
	case "$ecmd" in
		expect_exit)
			if [ "$rc" != "$earg" ]; then
				if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
					fail "TIMEOUT after ${TMO}s (wanted exit $earg) — possible interaction loop"
				else
					fail "exit=$rc wanted=$earg"
				fi
			fi ;;
		expect_timeout)
			case "$rc" in 124|137) : ;; *) fail "exit=$rc, wanted a harness-timeout end (124/137)" ;; esac ;;
		expect_config_has)
			grep -qF -- "$earg" "$CFG" 2>/dev/null || fail "config.json lacks: $earg" ;;
		expect_config_lacks)
			grep -qF -- "$earg" "$CFG" 2>/dev/null && fail "config.json unexpectedly has: $earg" ;;
		expect_trace)
			grep -qF -- "$earg" "$TRACE" 2>/dev/null || fail "trace lacks: $earg" ;;
		expect_trace_absent)
			grep -qF -- "$earg" "$TRACE" 2>/dev/null && fail "trace unexpectedly has: $earg" ;;
		expect_log)
			grep -qF -- "$earg" "$APPLOG" 2>/dev/null || fail "romm.log lacks: $earg" ;;
		expect_log_absent)
			grep -qF -- "$earg" "$APPLOG" 2>/dev/null && fail "romm.log unexpectedly has: $earg" ;;
		expect_file)
			[ -e "$SD/$earg" ] || fail "missing file: $earg" ;;
		expect_file_absent)
			[ -e "$SD/$earg" ] && fail "file exists but should not: $earg" ;;
		expect_file_empty)
			if [ ! -e "$SD/$earg" ]; then fail "missing file (stub deleted?): $earg"
			elif [ -s "$SD/$earg" ]; then fail "file has bytes but should be a 0-byte stub: $earg"
			fi ;;
		expect_file_has)
			tab="$(printf '\t')"
			case "$earg" in
				*"$tab"*) p="${earg%%"$tab"*}"; s="${earg#*"$tab"}" ;;
				*)        p="${earg%% *}"; s="${earg#* }" ;;
			esac
			grep -qF -- "$s" "$SD/$p" 2>/dev/null || fail "$p lacks: $s" ;;
		expect_file_lacks)
			tab="$(printf '\t')"
			case "$earg" in
				*"$tab"*) p="${earg%%"$tab"*}"; s="${earg#*"$tab"}" ;;
				*)        p="${earg%% *}"; s="${earg#* }" ;;
			esac
			grep -qF -- "$s" "$SD/$p" 2>/dev/null && fail "$p unexpectedly has: $s" ;;
		expect_file_lines)
			tab="$(printf '\t')"
			case "$earg" in
				*"$tab"*) p="${earg%%"$tab"*}"; n="${earg#*"$tab"}" ;;
				*)        p="${earg%% *}"; n="${earg#* }" ;;
			esac
			if [ -f "$SD/$p" ]; then got="$(grep -c . "$SD/$p" 2>/dev/null)"; else got=MISSING; fi
			[ "$got" = "$n" ] || fail "$p has $got non-blank line(s), wanted $n" ;;
		expect_tmp_lines)
			p="${earg%% *}"; n="${earg#* }"
			if [ -f "$p" ]; then got="$(grep -c . "$p" 2>/dev/null)"; else got=MISSING; fi
			[ "$got" = "$n" ] || fail "$p has $got non-blank line(s), wanted $n" ;;
		*) fail "harness: unknown expectation '$ecmd'" ;;
	esac
done < "$EXPECTS"

if [ "$fails" = 0 ]; then
	echo "PASS  $NAME${DESC:+  — $DESC}"
	[ "$KEEP" = "--keep" ] || rm -rf "$ROOT"
	exit 0
else
	echo "FAIL  $NAME${DESC:+  — $DESC}  (exit=$rc, artifacts: $ROOT)"
	exit 1
fi
