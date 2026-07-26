# onion-sim — off-device test harness for the OnionOS App/LodorSync shell flows

The OnionOS lane's whole shell surface — the App menu (`launch.sh`), the per-system launch
wrap (`bin/lodor-launch.sh`: download-on-launch, the always-show launch card, the post-game
save bracket), the wrap installer (`bin/lodor-seed.sh`) and the charging-gated daemon
(`bin/romm-syncd`) — is POSIX shell; only the binaries (`lodor-sync`, `prompt`, `infoPanel`)
are armhf. This harness runs the **real** scripts + `lib/romm-sync-lib.sh` on any x86 box
with stub binaries and scripted answers, cloned from the proven
`integrations/nextui/test/wizard-sim.sh` pattern.

## Run it

```sh
./check.sh                          # static gate (bash -n, busybox ash -n, shellcheck
                                    # --shell=busybox) + the full scenario matrix
sh run-all.sh                       # just the scenario matrix
sh run-all.sh c-card-play-default   # one scenario by name
bash onion-sim.sh scenarios/c-card-play-default.scn --keep   # keep the sandbox
```

Failed scenarios keep their sandbox under `/tmp/lodor-onionsim.<name>.*` — look at
`stdout.log`, `sim/trace.log` (every stub call), and `sdcard/` (the fake SD card).

## How stubbing works

* A throwaway **fake SD card** is built per scenario; the real App scripts are copied to
  `sdcard/App/LodorSync/` and stubs are placed at the exact paths the lib resolves:
  `App/LodorSync/lodor-sync` (the engine), `.tmp_update/bin/prompt` + `infoPanel` (the
  OnionOS MI-GFX UI binaries). `invoke wrap` stages the REAL `bin/lodor-launch.sh` as
  `Emu/<TAG>/launch.sh` with a RECORDER `launch.stock.sh` beside it (traces `STOCK`,
  optionally models RetroArch writing a save) — MainUI's exact launch contract.
* The onion lane has **no `LODOR_TEST_LIB` seam** (unlike NextUI), so the wlan0 probes are
  scripted by PATH-shadowing `cat` (intercepts exactly `/sys/class/net/wlan0/operstate`)
  and `ip` (intercepts `addr show wlan0`). Everything else in the lib runs REAL.
* `sleep` is PATH-shadowed with **scaled** compression (`N` → `N × LODOR_SIM_TICK`), not a
  flat tiny sleep — `lc_prompt` races a 15 s idle watchdog against the prompt answer, and
  flattening would auto-Play every card before the scripted pick. A genuinely unbounded
  loop still spins until `timeout` kills the scenario (reported as TIMEOUT).
* The charging gate (`is_charging` globs `/sys/class/power_supply/*/status`) is scripted by
  running daemon scenarios under `unshare -m` with a fake dir bind-mounted over
  `/sys/class/power_supply` (private propagation — the host never sees it; needs root).
  Daemon scenarios end by harness timeout **by design** (`expect_timeout`).
* Stubs read scripted behavior from per-channel queues (`stubs/simq`): **FIFO with a sticky
  last line** — repeated redraws/polls keep receiving the final answer. The `prompt` stub
  is faithful to the exit-code-as-selection contract (0..N-1, 255 = B) and validates the
  scripted index against the REAL item count (catching label/dispatch drift); `hang` never
  returns, exercising the idle watchdog. The `infoPanel` stub faithfully blocks on
  `/tmp/dismiss_info_panel` for `--persistent`, so ui_show/ui_dismiss run for real.
* **Harness invariant** (auto-checked in every scenario): each engine call must run with
  cwd == `LODOR_PAK_DIR` (config.json is CWD-relative) and `LODOR_PAK_DIR` +
  `SSL_CERT_FILE` exported — the stub tags `BADCWD`/`NOPAKDIR`/`NOSSL` and the harness
  fails on any occurrence.
* The lane pins fixed `/tmp` names (`romm-phase`, `romm-wifi.lock`, `lodor-lc-states.*`)
  with no env override, so scenarios run **sequentially** (run-all.sh does); the harness
  clears those names before each run.

Scenario directives are documented in the header of `onion-sim.sh`.

## Scope

Scenarios pin **shipped** behavior. Known lane gaps found while building this harness
(statecores.json never staged for OnionOS → states dark on-device; bracketed ROM names
break the save-push change detector; no `--push-states`/`--session-end` on this lane;
no rc=6 pairing-expired special-casing) are tracked as findings, not silently re-specified
here.
