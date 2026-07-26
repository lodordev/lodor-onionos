# Lodor-OnionOS integration (Miyoo Mini Plus, SigmaStar SSD202D)

**Status: active lane, not yet published from this repository.** Archived 2026-07-03, un-archived by
maintainer decision 2026-07-20. The build side is real — `release.sh` assembles `Lodor-OnionOS-<version>.zip`
on every release run and the lane is gated in CI — but no versioned release has been cut on this repo yet, so
the artifact is only available from the umbrella release page. The engine `-tags onion` variant, this App
tree, and the on-screen menu are fully built and hard-gated. **Validation honesty:** stub-mirror is
proven on Miyoo Mini Plus hardware (library shows, 0-byte stubs launch); the full pipeline
(download-on-launch, save sync) has been validated **off-hardware only** — on-device validation of
that path is still pending (see "Hardware-deferred" below).

No-fork OnionOS App that drives the portable Lodor engine. Stub-mirror is PROVEN on hardware (library
shows + 0-byte stubs launch). Full RomM pipeline validated from a CA-having host.

## Current release

**No release has been cut from this repository yet.** The OnionOS lane builds and is gated in CI, and its parity
work is merged, but no versioned artifact has been published here. Use the umbrella release page if you need the
OnionOS zip for a given version.

The 1.0 alpha currently covers muOS, LodorOS, and NextUI; OnionOS is expected to follow.

## Shipped fix vs the old pak
`App/LodorSync/certs/ca-certificates.crt` is now bundled. The on-device blocker was that the static Go
engine had no CA store, so HTTPS to the Cloudflare-fronted RomM failed TLS (silent `DLFAIL getrom`). The
lib already points `SSL_CERT_FILE` here first; muOS shipped one, OnionOS omitted it. That was the bug.

## On-screen menu (`menu/` -> `bin/lodor-menu`)
OnionOS MainUI shows no stdout, so the old echo+keypress `launch.sh` left a blank screen that read as a
crash. `launch.sh` now draws a real interactive menu via **`bin/lodor-menu`**, a CGO-free, stdlib-only
binary that writes `/dev/fb0` directly and reads `/dev/input/event*`. WHY a custom binary: OnionOS ships
no reusable interactive-menu primitive an App can call — its MainUI list builder is closed, and every
MinUI/NextUI tool (minui-list, minui-presenter, show2.elf) links libs absent on OnionOS (`/usr/trimui/lib`
+ SDL). Direct framebuffer is the only no-fork path. The renderer reuses the Lodor muOS lane's proven
`ui` package (vendored under `menu/ui/`; the fb backend reads the panel's REAL pixel format via ioctl, so
16- or 32-bpp both work). Built armhf-static + `static-go`-gated by `release.sh` (`build_onion_menu`).
- Menu entries: **Sync now** (`--push-pending` + `--mirror-catalog`), **Refresh library**
  (`--mirror-catalog` + `--mirror-collections`), **Library mode** (offline coexist Own<->Separate toggle,
  writes `data/settings.conf` `mirror_mode=`, never `config.json`), **Settings / status** (server, device,
  mode, last sync). All logic stays in the shell + engine; `lodor-menu` is host rendering only.

## Source layout (binary/config/token NOT committed — built by the release pipeline)
- `App/LodorSync/{launch.sh,icon.png}`, `bin/*.sh`, `lib/*.sh`, `data/config.json.example`, `certs/ca-certificates.crt`.
- `menu/` — Go source for `lodor-menu` (deployed to `App/LodorSync/bin/lodor-menu`).
- The `lodor-sync` engine + `lodor-menu` binaries are produced by `release.sh` (engine built with `-tags onion`).

## Engine variant (LANDED)
The onion-tagged engine files live in the canonical engine tree (`engine/platform/platform_onion.go`,
`states_onion.go`, `hoststate_onion.go` + their tests, all `//go:build onion`); `release.sh` builds
the variant from there with `-tags onion` (armhf, CGO-free static, static-go gated). The old "fold
the standalone port's engine changes back in" task is done — nothing onion-specific lives outside
`engine/` except this App tree and the menu renderer.

## Hardware-deferred (needs the maintainer + hardware)
Fresh RomM token (card token expired EOD 2026-06-27), then on-device: download-on-launch -> play -> save
-> around-session push; verify MMP charging sysfs node + `Saves/CurrentProfile/saves/<Core>` core-name map.
