# HANDOFF — WebVM iOS ("Hyper Cube")

_Written 2026-07-08 for pickup on a new host. The previous host (and sqrlbot's local
memory + signing keychain on it) may be gone — everything needed to continue is in
this repo._

## Where things stand

Branches `ios-app` and `main` are identical (work happens on `ios-app`; fast-forward
`main` after: `git push origin ios-app:main`). Latest TestFlight build **1783472292**
(VALID) contains everything below. App identity: display name **Hyper Cube**, bundle
`app.ish.iSH.KTGSS9PB3A` (literal — the team suffix is part of the id), ASC app record
6754670783 ("Placeholder (badmath)").

### Shipped and device-confirmed (2026-07-07)

- **Touch text-selection** (`enableNativeTouchSelection` in `src/lib/WebVM.svelte`):
  double-tap-drag word-select + extend, draggable start/end grips, floating Copy
  button. Driven by **pointer events + `setPointerCapture` calling `term.select()`
  directly**. Hard-won facts if this ever regresses:
  - Synthetic MouseEvents are a dead end on real iOS WebKit (a synthetic mousedown
    mid-touch silently kills the touch stream; sim passes, device fails).
  - A native `UIPanGestureRecognizer` on the WKWebView never fires (arbitrated away).
  - Touch events die after a double-tap (native recognizer cancels them) — pointer
    events with capture are immune; that's why the shipped code uses them.
  - `term.getSelectionPosition().end.x` is EXCLUSIVE (one past last cell) — no `+1`.
- **Trackpad two-finger scroll**: 0-touch `UIPanGestureRecognizer` with
  `allowedScrollTypesMask=[.continuous,.discrete]` (`ios/App/WasmWebView.swift`) →
  `window.__webvmWheelScroll` → `term.scrollLines`. (The disabled scrollView eats web
  `wheel` events — hence native; w-shell/Geistty pattern.)
- **Hyper Cube icon**: generated asset. Regenerate:
  `python3 ios/icon/hypercube_icon.py out.svg` → `rsvg-convert -w 2048 -h 2048` →
  flatten to opaque RGB + downsample to 1024 (Pillow, bg (5,3,12)) → `icon-1024.png`.
  All dials are constants at the top (palette / FIT / YOFF / bloom filter).
  `ios/icon/bloom_post.py` = alternate crisper raster-bloom finish. TestFlight
  REQUIRES an opaque (no-alpha) 1024² icon.
- **Tailscale connect watchdog** (`src/lib/network.js`): 25s timeout → "Can't reach
  Tailscale — retry". Gotcha: device DNS filters (NextDNS) sinkhole
  `controlplane.tailscale.com` → the old "Loading IP stack" hang; allowlist the host.

### Roadmap (CLAUDE.md is authoritative)

1. ✅ Boot in WKWebView   2. ✅ Internet via DirectSockets relay   6. ✅ Selection/copy
3. ❌ **BLOCKED** — VM-home ↔ iOS Documents mapping. Researched (6-agent workflow) +
   5 sim spike runs; report: `docs/research/2026-07-07-home-documents-blocked.md`.
   One-line verdict: the VM fs is natively opaque; a writable IDBDevice share works
   (r/w, relaunch persistence, full host↔guest round-trip proven) but exec-from-a-
   dir-mount wedges the VM — CheerpX 1.3.5 engine bug, only partially defusable
   page-side (noexec shim in the report; `chmod +x f && ./f` in-session still wedges).
   Owner declared it a showstopper. Revisit only if Leaning Tech fixes the exec path
   (no upstream bug filed — offer declined).
4. ⏳ **NEXT: lighter status bar / chrome** (mobile-first trim of the WebVM sidebar).
5. ⏳ **Fonts & colors** (xterm theme config; Blink Shell as UX reference).
   Both are pure web-layer, no engine risk.

## Build & publish on a NEW host

Two paths (details: CLAUDE.md + `ios/tools/README.md`):
- **Owner (cseaman)**: `cd ios && ./build.sh` (simulator) / `./testflight.sh` (upload;
  automatic signing with cseaman's cert; needs `ios/.asc.env` — copy from
  `.asc.env.example` — and the ASC `.p8` key at
  `~/.appstoreconnect/private_keys/AuthKey_YTYL3XKZXH.p8`).
- **sqrlbot autonomous**: `ios/tools/push-sqrlbot.sh` — BUT its signing setup was
  host-local (self-minted Apple Distribution cert in a dedicated `webvm-sign`
  keychain, sqrlbot-owned clone at `~sqrlbot/webvm-push`). On a new host rebuild it
  per `ios/tools/README.md` (cert via `asc_mkcert.py`, profile via `asc_mkprofile.py`;
  import needs legacy PKCS#12 + the WWDR-G3 intermediate +
  `security set-key-partition-list`). Until then, owner's `testflight.sh` works.
- **Verify any upload**: `uv run ios/tools/asc_webvm.py` (builds + processingState) or
  `asc_poll.py <buildNumber>`; needs only the `.p8` (API auth ≠ signing cert).
- Sim boot trace: `xcrun simctl spawn booted log show --style compact --last 2m
  --predicate 'subsystem == "app.ish.iSH.KTGSS9PB3A"'`.

## Environment gotchas (re-learned the hard way)

- Repo was group-writable `cseaman:sqrlbot` (`g+w`); owner-owned `.svelte-kit`/`build`
  dirs block in-place rebuilds by the automation user → build in a clone
  (push-sqrlbot.sh does).
- `npm install` needs SSH access to `git@github.com:leaningtech/labs.git`.
- IndexedDB (ALL VM persistence) is origin-keyed **including port** — LocalServer's
  fixed port 47821 is load-bearing; the ephemeral-port fallback orphans all VM state.
- `WEBVM_MODE=ios npm run build` selects `config_ios_terminal.js`; `ios/stage.sh`
  stages `build/` + the ext2 into `ios/web/webroot/` (needs
  `custom-disk-images/debian_mini.ext2` — not in git; from upstream releases).
- Temp scripts go in `.temp/` at repo root (gitignored), not /tmp.
- CheerpX pin: lockfile resolves `latest` → **1.3.5** (also the newest anywhere; CDN
  `LATEST.txt` agrees). The engine's FS layer `cheerpOS.js` is unminified with
  page-global functions — that's how the exec-hang was dissected; the engine loads
  from `cxrtnc.leaningtech.com` at runtime (CORP: cross-origin).

## Suggested first moves on the new host

1. Auth: `gh auth status` / SSH keys (repo + labs access), then `npm install`.
2. `debian_mini.ext2` → `custom-disk-images/`; `cd ios && ./build.sh`; confirm the
   sim boots to `user@:~$`.
3. If autonomous publishing is wanted, rebuild sqrlbot signing per
   `ios/tools/README.md`; else use owner's `./testflight.sh`.
4. Pick up roadmap #4 (chrome trim) — pure Svelte/CSS in `src/lib/`.
