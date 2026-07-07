# WebVM iOS — Handoff

_Last updated: 2026-07-06_

Status + priorities for the **WebVM-as-an-iOS/iPadOS-app** effort (WKWebView wrapper around the CheerpX-powered WebVM, shipped via TestFlight as a personal research project). For deep background see [`CLAUDE.md`](CLAUDE.md); for the full chronological reasoning/decision trail see [`DECISIONS.md`](DECISIONS.md) (an untracked working log — review and fold/drop as desired). Durable cross-session findings live in the auto-memory index.

---

## TL;DR

- **Working app** boots WebVM (Debian, terminal) in a full-screen WKWebView and ships to TestFlight.
- **General internet works** via Tailscale/lwIP + an admin-approved exit node.
- **Clipboard capture works**: `command | yank` → host clipboard (OSC 52 → native `UIPasteboard`), and **paste** (native `UIPasteboard`) both verified.
- **Latest TestFlight build: `1783365177` (VALID)** — awaiting on-device confirmation of `yank` + the scroll fix.
- **Touch text-selection: FIXED and sim-verified with real HID events (2026-07-06)** — two iOS-WebKit root causes found (synthetic mousedown mutes the touch stream; delayed tap-compat mouse bursts reset xterm selections); armed drags now ride the pointer stream + a trusted-mouse swallow window. Word-by-word drag-extension verified on-simulator via XCUITest; **device confirmation pending** (next TestFlight build). iPhone layout/viewport still needs work.
- Branch: **`ios-app`** (pushed to `origin`). Everything below is committed except `DECISIONS.md`.

---

## What works (shipped & verified)

| Area | State | How verified |
| --- | --- | --- |
| Boot to shell in WKWebView (iPad) | ✅ | Simulator + device; `crossOriginIsolated`, SAB, JIT all fine on real WebKit |
| General internet (curl/apt/getent, DNS) | ✅ | Device + Playwright: `HTTP 200`, DNS resolves, through Tailscale exit node |
| Paste (clipboard → shell) | ✅ | Device: native `UIPasteboard` bridge (`nativePaste`); one-time iOS "Allow Paste" prompt per install |
| `command \| yank` → clipboard (OSC 52) | ✅ | Simulator via `simctl pbpaste`; Playwright fallback path. **Device confirmation pending.** |
| `yank` guest command | ✅ | `/usr/local/bin/yank` (stdin or file → OSC 52); on default PATH |
| Copy button (touch, from a selection) | ✅ (logic) | Playwright; routes through `webvmCopy` (native in WKWebView) |
| No page-pan / header-scroll-off | ✅ (fix in) | Code fix shipped (`scrollView.isScrollEnabled=false`); **device confirmation pending** |

### Networking model (settled)
- **Use the Tailscale/lwIP path**, not DirectSockets, for anything needing to reach the internet with stock tools.
- **DirectSockets (device-direct, no Tailscale) is a dead end for stock C tools** — a CheerpX engine limitation: inbound bytes are `postMessage`'d to the guest worker without the async wake sentinel that keyboard/disk-IO use, so a parked C `recv()` never wakes (only CPython's constantly-syscalling runtime happened to). Exhaustively tested; see the `directsockets-recv-engine-limitation` memory. The UDP-over-DirectSockets transport code still exists and works at the transport layer — it's just dormant (not selected in `config_ios_terminal.js`).
- **Exit node**: general internet requires an **admin-approved** exit node in the Tailscale console (a device merely advertising `--advertise-exit-node` isn't enough). Once approved, the engine's own netmap auto-select handles it — no client-side hack. See `tailscale-exitnode-acl-gap` memory.
- **Do not chase the "controlplane DNS blocked" red herring** — the local Pi-hole resolvers sinkhole `controlplane.tailscale.com`, but the system resolves it fine via public fallbacks; test reachability with `curl -sI`, not `dig`. See `tailscale-control-dns-blocked` memory.

---

## In progress / deferred (with specifics)

### 1. Touch text-selection — FIXED (sim-verified with real events; device confirmation pending)
Gesture unchanged: **double-click / double-tap + drag** for word-based selection; single-tap-drag stays reserved for scrolling. The 2026-07-06 session built a real-HID-event rig (XCUITest driver + injected raw-event tracer; see the auto-memory `webvm-real-event-test-rig`) and root-caused the failure — it was never a gesture-recognizer/zoom problem:
1. **Dispatching the synthetic `mousedown` mutes the touch stream** (iOS WebKit): after the bridge's `mousedown(detail:2)`, no `touchmove`/`touchend`/`touchcancel` is ever delivered for that finger (isolated via a 5-way matrix; independent of `preventDefault`/`stopPropagation`/sync-vs-deferred). The **pointer stream keeps flowing** — so the armed drag is now driven from document-level `pointermove`/`pointerup`/`pointercancel`.
2. **Delayed tap-compatibility mouse bursts** (`mousemove, mousedown detail:1, mouseup, click`, 50ms–4.2s after every un-preventDefault'ed tap — the first tap of a double-tap can't be preventDefault'ed): the burst's `mousedown(detail:1)` resets xterm's selection and its `mouseup` detaches xterm's drag listeners (kill reproduced deterministically). Fixed with a 5s trusted-mouse swallow window over the terminal while armed/recently armed (`isTrusted` discrimination — synthetic bridge events pass; the Copy button lives outside the suppressed subtree).
- ✅ Verified on-simulator with real HID events: word-by-word growth `"powered" → … → "powered by the CheerpX virtualization engine, which"`, selection persists ≥6s and across an intervening scroll-drag, gesture repeatable, plain drags don't arm, production 300ms double-tap arming + real-burst survival verified via `XCUICoordinate.doubleTap()`.
- ⏳ Real-device (iPhone/iPad) confirmation via next TestFlight build. If a device still fails, the one mechanism the simulator could not exhibit is UIKit's text-interaction recognizers (loupe/"TapAndAHalfRecognizer") claiming the touch — contingency: `webView.configuration.preferences.isTextInteractionEnabled = false` (iOS 14.5+; side effect: kills native selection in any DOM text inputs, e.g. sidebar fields).

### 2. iPhone viewport / layout — NOT ADAPTED
The UI is iPad-tuned. On iPhone the nav header/sidebar and scroll handling don't fit the form factor, and tap+drag still pans. Needs a mobile/responsive pass (this ties into the roadmap "status bar lighter weight" item).

### 3. Selection bonus items — UNBUILT
- **Auto-scroll while dragging a selection past the viewport edge**: xterm.js has an internal `_dragScroll` timer that should give this "for free," but it didn't engage in testing (likely needs continuous drag events, not one-shot). Unbuilt.
- **Draggable selection handles** (iOS-style start/end grips): xterm.js has no built-in touch-handle UI — this is a from-scratch build. Deferred.

### 4. Reproducibility of `yank` in the disk image
`yank` was **manually injected** into the (gitignored) `custom-disk-images/debian_mini.ext2` via a privileged Docker loop-mount. The Dockerfile now bakes it (`dockerfiles/rootfs/usr/local/bin/yank` + a `COPY` in `dockerfiles/debian_mini`), but the **canonical image should be rebuilt via the Deploy workflow** so the bundled image and the Dockerfile don't drift. Until then, note the manual-injection caveat.

---

## Priorities (suggested order)

1. **Confirm the current TestFlight build on-device** — `yank` capture + single-finger scroll (no page-pan). See "What should I be testing" checklist / the test table above. This gates whether the clipboard-capture milestone is truly done.
2. **Touch selection on-device debugging** — attach Safari Web Inspector to the WKWebView and trace real touch events; decide whether the fix is a gesture-recognizer tweak, an event-handling change, or a different interaction model. Highest-value UX gap.
3. **iPhone layout/viewport pass** — make the app usable on iPhone (currently iPad-only in practice).
4. **Rebuild the canonical disk image** via the Deploy workflow so `yank` (and any future guest tooling) is baked reproducibly, not manually injected.
5. **Roadmap items** (from `CLAUDE.md`, owner's priority order): home dir ↔ iOS Documents mapping; trim the status bar/sidebar chrome for mobile; xterm fonts/colors/themes; richer select/copy/paste + touch pass-through.
6. **CheerpX licensing** — unresolved blocker for any *App Store* (non-TestFlight) distribution; self-hosting/redistributing a CheerpX build needs a commercial license. Fine for personal TestFlight research; revisit before any public release.

---

## Key gotchas learned this session (save yourself the pain)

- **Simulator page staleness**: `simctl launch` on an already-running app only foregrounds it — it does NOT reload the WKWebView, so you keep testing the old in-memory page. **Always `simctl terminate` before `launch`** (or re-run `ios/build.sh`, which reinstalls). A quick canary: type `echo not new` — if it survives a "relaunch," the page is stale.
- **Playwright can't verify WKWebView-specific behavior** — anything gated on user-activation (clipboard read/write) or native gesture recognizers (zoom, scroll, selection) behaves differently or not at all in desktop Chromium. For those, use **`simctl pbcopy`/`pbpaste` + a temporary in-app hook** (drive the exact code path on boot, read the pasteboard from the host). Playwright is still the right tool for logic/pipeline/VT verification.
- **Clipboard needs a user gesture in WKWebView** — both `writeText` and `readText`. Anything not driven by a tap (OSC 52 copy fires from terminal output) must go through the native `UIPasteboard` bridge, not the Clipboard API. Copy uses `nativeCopy`, paste uses `nativePaste` (`ios/App/WasmWebView.swift`).
- **Disk-image / IDB cache staleness**: the `IDBDevice` block cache can serve stale blocks of a changed disk image on a device that already ran the old one. Fresh installs get a clean cache; otherwise use the app's **reset** button (sidebar). If a newly-added guest command is "not found," this is why.
- **Test coordinate math**: when synthesizing terminal touch/mouse coords, character width is `rowRect.width / term.cols` (real column count), **not** `/ textContent.length` — that bug made a working selection look broken for a while.
- **iOS WebKit: synthetic `mousedown` during a live touch mutes that touch stream** (no touchmove/touchend/touchcancel ever again; pointer events unaffected). Any touch→mouse bridge must drive drags from pointer events. Verified via a 5-way isolation matrix of real HID events.
- **iOS WebKit: every un-preventDefault'ed tap fires a DELAYED trusted mouse burst** (`mousedown detail:1` + `mouseup` + `click`, 50ms–4.2s late under CheerpX load) that resets xterm selections. `user-scalable=no` genuinely disables double-tap-zoom (WebKit-source-verified) — it was never the interceptor.
- **XCUITest gesture calls have a 3–11s inter-call gap** — a real <300ms double-tap can't be composed from `tap()`+`press()`. Use `doubleTap()` for production-timing arming tests; a temporary `window.__DEBUG_DOUBLE_TAP_MS` knob for armed-drag tests.

---

## Build & test workflows

```sh
# --- Simulator (fast iteration) ---
cd ios && ./build.sh            # WEBVM_MODE=ios build → stage web+disk → xcodegen → build → INSTALL+LAUNCH on sim
                                # (reinstalls, so it avoids the stale-page trap)

# --- TestFlight ---
cd ios && ./testflight.sh       # timestamp CFBundleVersion → archive (Release) → sign → upload (needs ios/.asc.env + the .p8)
cd ios && ./upload_only.sh      # re-upload the LAST archive without rebuilding

# --- ASC build status ---
# scratchpad has an asc_webvm.py helper (recreate if scratchpad cleared) that lists recent builds + processingState.

# --- Local Playwright rig (logic/pipeline/VT verification) ---
# A COI+Range Python server (coi_server.py, in the session scratchpad) serves build/ on 127.0.0.1:8123.
#   WEBVM_MODE=ios npm run build && mkdir -p build/disk && cp custom-disk-images/debian_mini.ext2 build/disk/
#   Range/206 + Last-Modified + COOP/COEP/CORP headers are REQUIRED or CheerpX won't boot.
#   Emulate touch by injecting an init script that overrides navigator.maxTouchPoints + window.ontouchstart.

# --- Editing the guest disk image (until the Deploy workflow rebuild) ---
# Privileged Docker loop-mount of custom-disk-images/debian_mini.ext2, cp the file in, chmod, sync, umount.
```

**App identity**: bundle `app.ish.iSH.KTGSS9PB3A` (literal — embeds the team suffix), team `KTGSS9PB3A`, ASC app id `6754670783` ("Hyper-Cube" record). Signing is fully automatic via the `.p8` API key in `ios/.asc.env` (gitignored). Networking authKey/controlUrl are baked from `ios/.network.env` (gitignored) at stage time.

---

## Pointers

- **`CLAUDE.md`** — architecture, constraints, the iOS-conversion plan and roadmap.
- **`DECISIONS.md`** — full session decision log (wterm-vs-xterm reversal, every root-cause, cleanup rationale). Untracked; fold into commit messages or drop when reviewed.
- **Auto-memory** (index at `~/.claude/projects/-Users-cseaman-Documents-webvm/memory/MEMORY.md`): `directsockets-recv-engine-limitation`, `tailscale-exitnode-acl-gap`, `tailscale-control-dns-blocked`, `ios-dns-root-cause` — the durable networking findings.
- **Key files**: `src/lib/WebVM.svelte` (terminal + CheerpX boot + copy/paste/selection), `ios/App/WasmWebView.swift` (WKWebView + native clipboard bridges + scroll config), `src/app.html` (viewport meta), `config_ios_terminal.js` (iOS run config), `src/lib/network.js` (Tailscale interface), `dockerfiles/debian_mini` (+ `dockerfiles/rootfs/`) (guest image source).
