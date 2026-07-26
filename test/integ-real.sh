#!/bin/sh
# integ-real.sh — REAL-engine end-to-end leg for Lodor-OnionOS (beta1 test B).
#
# Drives the ACTUAL armhf lodor-sync (the shipping binary) under qemu-arm — an arm32v7
# docker image with --cpuset-cpus=1 (the golang#67355 "taskset -c 1" mitigation) — against
# a disposable test RomM (release/test-romm), asserting on-disk bytes AND server REST state:
#   1. --register-device      -> RESULT registered=1 + config.json gains device_id
#   2. --mirror-catalog       -> real stubs land in Roms/ + catalog-index.json written
#   3. resumable --download    through a MID-STREAM-TRUNCATING proxy: attempt 1 truncates
#      (partial .tmp kept), attempt 2 resumes via HTTP Range and completes (bytes == server)
#   4. save round-trip        -> --push-save then GET /api/saves shows the save for its rom_id
#   5. save-STATE mode         -> stages a real statecores.json, asserts --push-states/--list-states
#      RUN + report HONESTLY (no-manifest gone; reason ok/no-states; no FATAL). A REAL state
#      upload needs an emulator-produced state -> proven by engine/sync/statesync_test.go + on-device.
#
# LOUD-SKIP CONTRACT: exits 3 (a SKIP, never a pass) when docker / arm binfmt / test-romm /
# python3 / curl are unavailable — the missing input is printed on the LAST line. A real
# assert failure exits 1; a clean end-to-end run exits 0.
#
# Env: LODOR_KEEP_ROMM=1 leaves test-romm up (skip down.sh) — for a shared build host.
#
# shellcheck disable=SC2015  # `cond && ok || bad` assert idiom: ok/bad only echo+count, C never runs spuriously
# shellcheck disable=SC2329  # teardown() is invoked indirectly via `trap teardown EXIT`
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ONION=$(CDPATH= cd -- "$HERE/.." && pwd)
REPO=$(CDPATH= cd -- "$ONION/../.." && pwd)
GO_IMG="${LODOR_GO_IMG:-golang:1.25-bookworm}"
ARM_IMG="${LODOR_ARM_IMG:-arm32v7/debian:bookworm-slim}"
BASE="http://127.0.0.1:8998"
ADMIN_USER=testadmin
ADMIN_PASS=testadmin-pw
PROXY_PORT="${LODOR_PROXY_PORT:-8997}"
PROXY_BASE="http://127.0.0.1:$PROXY_PORT"
SB="${LODOR_SB:-/tmp/lodor-onion-integ}"
CARD="$SB/card"
DATA="$CARD/App/LodorSync/data"
ROMS="$CARD/Roms"
SAVES="$CARD/Saves/CurrentProfile/saves"

fails=0
ok(){ echo "ok: $*"; }
bad(){ echo "FAIL: $*"; fails=$((fails+1)); }
skip(){ echo ""; echo "SKIP (loud, not a pass): $1"; exit 3; }

# ---- 0. dependency probes -> loud SKIP (exit 3, never a pass) ----
command -v docker  >/dev/null 2>&1 || skip "docker unavailable"
command -v curl    >/dev/null 2>&1 || skip "curl unavailable"
command -v python3 >/dev/null 2>&1 || skip "python3 unavailable (REST asserts + truncating proxy)"
docker run --rm --platform linux/arm/v7 "$ARM_IMG" true >/dev/null 2>&1 \
  || skip "arm/v7 binfmt not runnable (need qemu-user-static registered for linux/arm/v7, image $ARM_IMG)"

rm -rf "$SB"; mkdir -p "$DATA" "$ROMS" "$SAVES" || skip "cannot create sandbox $SB"

PROXY_PID=""
teardown(){
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
  if [ "${LODOR_KEEP_ROMM:-0}" != 1 ]; then
    echo ">> tearing down test-romm..."
    sh "$REPO/release/test-romm/down.sh" >/dev/null 2>&1 || true
  fi
}
trap teardown EXIT INT TERM

# ---- 1. test-romm: FRESH + CONSISTENT DB (fix #3). RomM's persistent volume can hold a STALE
# sha1 from a prior run that mismatches the current on-disk fixture (metadata sha1 != served
# content sha1) -> the engine's hash-verify CORRECTLY rejects the download, and it looks like a
# content-serving failure. down.sh nukes volumes/ (keeps library/ fixtures); up.sh then rescans
# the CURRENT fixtures into a consistent DB. This is what makes the leg a trustworthy gate.
echo ">> resetting test-romm to a fresh DB (down.sh -> up.sh)..."
sh "$REPO/release/test-romm/down.sh" >/dev/null 2>&1 || true
sh "$REPO/release/test-romm/up.sh" > "$SB/romm-up.log" 2>&1 || skip "test-romm up.sh failed (see $SB/romm-up.log)"
curl -sf "$BASE/api/heartbeat" >/dev/null 2>&1 || skip "test-romm not reachable at $BASE"

# a fixture rom + its id (up.sh seeds lodor-fixture-alpha.gba etc.)
ROM_JSON=$(curl -sf -u "$ADMIN_USER:$ADMIN_PASS" "$BASE/api/roms?limit=50" 2>/dev/null)
FIX_ID=$(printf '%s' "$ROM_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin); items=d if isinstance(d,list) else d.get("items",[])
for r in items:
    if str(r.get("fs_name","")).endswith(".gba"):
        print(r["id"]); break
' 2>/dev/null)
FIX_NAME=$(printf '%s' "$ROM_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin); items=d if isinstance(d,list) else d.get("items",[])
for r in items:
    if str(r.get("fs_name","")).endswith(".gba"):
        print(r.get("fs_name","")); break
' 2>/dev/null)
[ -n "$FIX_ID" ] || skip "no .gba fixture visible over REST (test-romm not seeded?)"
echo ">> fixture rom: id=$FIX_ID fs_name=$FIX_NAME"
# Content-servability probe: the resume + save-round-trip legs (3-4) need test-romm to actually
# SERVE ROM content (GET /api/roms/<id>/content/<fs_name>). Some test-romm fronts (nginx) don't
# proxy the content route -> those legs LOUD-SKIP (never red-FAIL a beta1 regression that isn't
# there); 1/2/5 still exercise the real engine. A 200 means content is servable -> run them.
CONTENT_OK=0
# RomM surfaces rom metadata (cron rescan) BEFORE the file association makes content servable,
# so a single probe races and false-SKIPs. Poll up to ~60s for a real 200 before deciding.
_ci=0; while [ "$_ci" -lt 30 ]; do
	curl -sf -o /dev/null -u "$ADMIN_USER:$ADMIN_PASS" "$BASE/api/roms/$FIX_ID/content/$FIX_NAME" && { CONTENT_OK=1; break; }
	_ci=$((_ci+1)); sleep 2
done
SKIP_CONTENT=0

# ---- engine runner: armhf under qemu-arm (arm32v7 image), pinned to CPU 1, host net ----
# cwd=/card/App/LodorSync/data so config.json (CWD-relative) + LODOR_PAK_DIR resolve there.
eng(){
  docker run --rm --network host --platform linux/arm/v7 --cpuset-cpus=1 \
    -v "$SB/lodor-sync":/lodor-sync:ro -v "$CARD":/card \
    -w /card/App/LodorSync/data \
    -e SDCARD_PATH=/card -e BASE_PATH=/card -e LODOR_PAK_DIR=/card/App/LodorSync/data \
    -e LODOR_SKIP_EMU_GATE=1 -e LODOR_HOST_OS=onion \
    "$ARM_IMG" /lodor-sync "$@"
}
write_config(){  # <root_uri> : rewrite config.json, PRESERVING an existing device_id (fix #1)
  # Leg 1 stamps device_id into config.json; legs 3+ rewrite config (proxy<->base root_uri) and
  # MUST keep it — a device-less rewrite makes --push-save/--push-states correctly FATAL
  # (no device_id). Capture the existing key verbatim and re-embed it in the host object.
  _did=$(grep -o '"device_id"[[:space:]]*:[[:space:]]*[^,}]*' "$DATA/config.json" 2>/dev/null | head -1)
  _did_frag=""
  [ -n "$_did" ] && _did_frag=", $_did"
  cat > "$DATA/config.json" <<CFG
{
  "hosts": [
    { "root_uri": "$1", "username": "$ADMIN_USER", "password": "$ADMIN_PASS", "device_name": "onion-integ"$_did_frag }
  ],
  "mirror_mode": "own",
  "api_timeout": 30,
  "download_timeout": 3600
}
CFG
}

# ---- build the shipping armhf engine (CGO-free static) ----
echo ">> building armhf lodor-sync (CGO_ENABLED=0 GOARCH=arm GOARM=7 -tags onion)..."
VERSION=$(cat "$REPO/VERSION" 2>/dev/null || echo dev)
# -tags onion: this leg exercises the SHIPPING OnionOS variant (onion tag map + Emu-pak gate
# + roots), exactly what release.sh builds — NOT the default engine (whose platform map differs).
if docker run --rm -v "$REPO/engine":/src -w /src \
     -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=arm -e GOARM=7 "$GO_IMG" \
     go build -tags onion -trimpath -ldflags "-s -w -X lodor/buildinfo.Version=$VERSION" \
     -o /src/.integ-real-armhf ./cmd/lodor-sync > "$SB/build.log" 2>&1 \
   && [ -f "$REPO/engine/.integ-real-armhf" ]; then
  mv "$REPO/engine/.integ-real-armhf" "$SB/lodor-sync"; chmod +x "$SB/lodor-sync"
else
  skip "armhf engine build failed (see $SB/build.log)"
fi
eng --version >/dev/null 2>&1 || skip "armhf engine will not run under qemu-arm (see qemu-preflight)"

echo ""
echo "=== leg 1: --register-device (REST device create + config device_id) ==="
write_config "$BASE"
REG=$(eng --register-device "onion-integ" 2>&1)
echo "$REG" | grep -q "RESULT registered=1" \
  && ok "engine reported registered=1" \
  || bad "register-device did not report registered=1 ($(echo "$REG" | grep RESULT | head -1))"
if grep -q '"device_id"' "$DATA/config.json"; then
  ok "config.json carries a device_id after register ($(grep -o '"device_id":[^,}]*' "$DATA/config.json" | head -1))"
else
  bad "config.json has no device_id after --register-device"
fi

echo ""
echo "=== leg 2: --mirror-catalog (stubs land + catalog index) ==="
MIR=$(eng --mirror-catalog 2>&1)
echo "$MIR" | grep -q "^MIRROR" && ok "engine printed a MIRROR summary ($(echo "$MIR" | grep '^MIRROR' | head -1))" \
  || bad "no MIRROR summary line from --mirror-catalog"
STUB=$(find "$ROMS" -type f -name '*.gba' 2>/dev/null | head -1)
[ -n "$STUB" ] && ok "a .gba stub was created in Roms/ ($(basename "$STUB"))" \
  || bad "no .gba stub created under $ROMS"
[ -f "$DATA/catalog-index.json" ] && ok "catalog-index.json written" || bad "catalog-index.json missing"

# fix #2: the DOWNLOADED stub (STUB) is NOT necessarily the first API rom (FIX_ID). Derive the
# stub's OWN rom id from its fs_name (strip the ✘/✓ state marker) so the save/state REST asserts
# query the rom a real save actually lands under — not FIX_ID's.
_stub_fs=$(basename "$STUB" | sed 's/^✘ //; s/^✓ //')
DL_ROM_ID=$(printf '%s' "$ROM_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin); items=d if isinstance(d,list) else d.get("items",[])
want=sys.argv[1]
for r in items:
    if str(r.get("fs_name",""))==want:
        print(r["id"]); break
' "$_stub_fs" 2>/dev/null)
[ -n "$DL_ROM_ID" ] || DL_ROM_ID="$FIX_ID"
echo ">> downloaded rom: stub='$(basename "$STUB")' fs_name='$_stub_fs' id=$DL_ROM_ID"

echo ""
if [ "$CONTENT_OK" != 1 ]; then
  echo "=== legs 3-4 (download resume + save round-trip): LOUD-SKIP ==="
  echo "SKIP: test-romm does not serve ROM content at /api/roms/$FIX_ID/content/$FIX_NAME (probe != 200)."
  echo "      resume + save round-trip need a content-serving RomM; register/mirror/states above are real."
  SKIP_CONTENT=1
else
echo "=== leg 3: resumable --download through a mid-stream-truncating proxy (HTTP Range) ==="
# The proxy forwards every request to test-romm, but the FIRST GET of a /content/ path is
# TRUNCATED after TRUNC_BYTES (connection closed early) -> the engine keeps a partial .tmp.
# The engine's SECOND --download sends Range: bytes=<offset>- ; the proxy forwards it whole
# and records that a Range request arrived -> proof the resume path (not a fresh refetch) ran.
cat > "$SB/proxy.py" <<'PY'
import http.server, socketserver, urllib.request, os, sys, threading
BASE=os.environ["PROXY_TARGET"]; TRUNC=int(os.environ.get("TRUNC_BYTES","4096"))
STATE={"truncated":False}; FLAG=os.environ["PROXY_FLAG"]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*a): pass
    def _relay(self):
        body=None
        cl=self.headers.get("Content-Length")
        if cl: body=self.rfile.read(int(cl))
        req=urllib.request.Request(BASE+self.path, data=body, method=self.command)
        for k,v in self.headers.items():
            if k.lower() in ("host","content-length","connection"): continue
            req.add_header(k,v)
        is_content="/content/" in self.path
        rng=self.headers.get("Range")
        if is_content and rng:
            open(FLAG,"a").write("RANGE %s\n"%rng)   # proof: engine resumed with a Range
        try:
            r=urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            r=e
        data=r.read()
        # first content GET with NO range -> truncate mid-stream (close after TRUNC bytes)
        if is_content and not rng and not STATE["truncated"]:
            STATE["truncated"]=True
            self.send_response(getattr(r,"status",200))
            self.send_header("Content-Length", str(len(data)))
            for k,v in r.headers.items():
                if k.lower() in ("content-length","transfer-encoding","connection"): continue
                self.send_header(k,v)
            self.end_headers()
            try: self.wfile.write(data[:TRUNC])
            except Exception: pass
            self.close_connection=True
            return
        self.send_response(getattr(r,"status",200))
        for k,v in r.headers.items():
            if k.lower() in ("transfer-encoding","connection"): continue
            self.send_header(k,v)
        if "Content-Length" not in r.headers: self.send_header("Content-Length",str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except Exception: pass
    do_GET=_relay; do_POST=_relay; do_PUT=_relay; do_DELETE=_relay
    def do_HEAD(self): self._relay()
class S(socketserver.ThreadingTCPServer): allow_reuse_address=True
S(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
FLAGF="$SB/proxy-range.flag"; : > "$FLAGF"
PROXY_TARGET="$BASE" PROXY_FLAG="$FLAGF" TRUNC_BYTES=4096 \
  python3 "$SB/proxy.py" "$PROXY_PORT" >/dev/null 2>&1 &
PROXY_PID=$!
i=0; until curl -sf -u "$ADMIN_USER:$ADMIN_PASS" "$PROXY_BASE/api/heartbeat" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 30 ] && break; sleep 0.3
done
SRV_BYTES=$(curl -sf -u "$ADMIN_USER:$ADMIN_PASS" "$BASE/api/roms/$DL_ROM_ID" 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("fs_size_bytes",0))' 2>/dev/null)
write_config "$PROXY_BASE"
STUBREL=$(printf '%s' "$STUB" | sed "s#^$CARD/##")
echo ">> download target: /$STUBREL (server bytes=$SRV_BYTES)"
eng --download "/card/$STUBREL" > "$SB/dl1.log" 2>&1 || true
SZ1=$(wc -c < "$STUB" 2>/dev/null || echo 0)
if grep -q RANGE "$FLAGF" 2>/dev/null; then : ; fi   # (range may only appear on attempt 2)
eng --download "/card/$STUBREL" > "$SB/dl2.log" 2>&1 || true
SZ2=$(wc -c < "$STUB" 2>/dev/null || echo 0)
grep -q "RANGE" "$FLAGF" 2>/dev/null \
  && ok "engine resumed with an HTTP Range request ($(head -1 "$FLAGF"))" \
  || bad "no Range request seen at the proxy (resume path not exercised; attempt1 size=$SZ1)"
if [ -n "$SRV_BYTES" ] && [ "$SRV_BYTES" -gt 0 ] 2>/dev/null; then
  [ "$SZ2" = "$SRV_BYTES" ] \
    && ok "downloaded file is complete after resume ($SZ2 == server $SRV_BYTES)" \
    || bad "downloaded file size $SZ2 != server $SRV_BYTES after resume"
else
  [ "$SZ2" -gt "$SZ1" ] 2>/dev/null \
    && ok "resume advanced the file ($SZ1 -> $SZ2 bytes; server size unknown)" \
    || bad "resume did not advance the file (stayed $SZ2)"
fi
kill "$PROXY_PID" 2>/dev/null; PROXY_PID=""
write_config "$BASE"

echo ""
echo "=== leg 4: save round-trip (--push-save -> GET /api/saves) ==="
STEM=$(basename "$STUB" .gba)
mkdir -p "$SAVES/mGBA"
printf 'LODOR-ONION-SAVE-%s\n' "$(date +%s)" > "$SAVES/mGBA/$STEM.srm"
PS=$(eng --push-save "/card/$STUBREL" 2>&1)
echo "$PS" | grep -q "RESULT" && echo ">> push-save: $(echo "$PS" | grep RESULT | head -1)"
SV_N=$(curl -sf -u "$ADMIN_USER:$ADMIN_PASS" "$BASE/api/saves?rom_id=$DL_ROM_ID" 2>/dev/null \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else len(d.get("items",[])))' 2>/dev/null)
[ "${SV_N:-0}" -ge 1 ] 2>/dev/null \
  && ok "server has >=1 save for the rom over REST (GET /api/saves count=$SV_N)" \
  || bad "no save visible over REST after --push-save (count=${SV_N:-0})"

fi   # end CONTENT_OK gate for legs 3-4

echo ""
echo "=== leg 5: save-STATE mode runs honestly with a real manifest (no fake state blob, fix #4) ==="
STUBREL="${STUBREL:-Roms/GBA/$(basename "$STUB")}"
[ -n "${STUBREL#Roms/GBA/}" ] || STUBREL=$(printf '%s' "$STUB" | sed "s#^$CARD/##")
# HONESTY (fix #4): --push-states validates state FORMAT via statefmt.ExtractRaw and scans
# StateFilesForRom by REAL emulator naming — a hand-written text file legitimately yields
# no-states. A true state round-trip needs a REAL emulator-produced state = the on-device D/E
# smoke. So we DO stage statecores.json (so the mode is NOT no-manifest) and assert the mode
# RUNS + reports HONESTLY (reason ok/no-states, never a FATAL). We do NOT fabricate a state blob.
echo ">> staging statecores.json (release/mkstatecores.sh, gba=mgba:mGBA)"
sh "$REPO/release/mkstatecores.sh" --frontend onion --arch armhf --out "$DATA/statecores.json" \
  gba=mgba:mGBA >/dev/null 2>&1 || bad "mkstatecores.sh failed to emit statecores.json"
PST=$(eng --push-states "/card/$STUBREL" 2>&1)
echo ">> push-states: $(echo "$PST" | grep RESULT | head -1)"
if echo "$PST" | grep -q "RESULT" && ! echo "$PST" | grep -qi "FATAL"; then
  if echo "$PST" | grep -qE 'reason=(ok|no-states)'; then
    ok "--push-states ran with a real manifest + reported honestly (reason ok/no-states, no FATAL, no-manifest gone)"
  else
    bad "--push-states ran but reason unexpected ($(echo "$PST" | grep -o 'reason=[^ ]*' | head -1))"
  fi
else
  bad "--push-states did not report cleanly ($(echo "$PST" | grep -iE 'RESULT|FATAL' | head -1))"
fi
ST_N=$(curl -sf -u "$ADMIN_USER:$ADMIN_PASS" "$BASE/api/states?rom_id=$DL_ROM_ID" 2>/dev/null \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else len(d.get("items",[])))' 2>/dev/null)
echo ">> server states for rom $DL_ROM_ID over REST: ${ST_N:-0} (0 expected — no REAL emulator state on card)"
LST=$(eng --list-states "/card/$STUBREL" 2>&1)
echo "$LST" | grep -q "RESULT" && ! echo "$LST" | grep -qi "FATAL" \
  && ok "--list-states ran + reported (no FATAL)" \
  || bad "--list-states did not report cleanly ($(echo "$LST" | grep -iE 'RESULT|FATAL' | head -1))"
echo ">> real state UPLOAD is proven by engine/sync/statesync_test.go (unit) + the on-device D/E leg, NOT here"

echo ""
echo "======================================================================"
if [ "$fails" = 0 ] && [ "$SKIP_CONTENT" = 1 ]; then
  echo "integ-real: register/mirror/state legs PASSED; download+save legs SKIPPED (no content served)"
  echo ""
  echo "SKIP (loud, not a pass): test-romm did not serve ROM content — legs 3-4 could not run"
  exit 3
fi
if [ "$fails" = 0 ]; then
  echo "integ-real: ALL REAL-ENGINE ASSERTS PASSED"
  exit 0
fi
echo "integ-real: $fails assert(s) FAILED"
exit 1
