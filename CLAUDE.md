# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project intent

This is a **fork** of [leaningtech/webvm](https://github.com/leaningtech/webvm) (`origin` = `christopherseaman/webvm`, `upstream` = `leaningtech/webvm`). WebVM is a browser-based x86 Linux VM. The active goal of this fork is to run **WebVM as an iOS/iPadOS app** (WKWebView wrapper) distributed via TestFlight — a **personal research project**, not App Store distribution. The working app lives in `ios/` (boots to a shell, uploads to TestFlight). See [iOS conversion](#ios-conversion).

### Working rules (from the project owner)

- **Always use workflows / agent teams** for non-trivial work (parallel analysis, multi-file changes, review). Solo edits only for trivial/mechanical changes.
- **Seek root causes; make elegant fixes.** No band-aids over symptoms.
- **DRY / KISS / YAGNI.** Reuse before writing; no speculative abstraction.
- **Prefer off-the-shelf components over building our own** (e.g. WKWebView, an existing local-server lib, an existing TestFlight script) whenever one exists.

## What WebVM is (architecture)

WebVM is a **SvelteKit static site** (`@sveltejs/adapter-static`, `prerender=true` on every route — there is **no server runtime**) whose entire job is to boot a full x86 Linux VM client-side using the **CheerpX** WebAssembly engine (the `@leaningtech/cheerpx` npm package — a closed-source x86→WASM JIT, virtual block FS, and Linux syscall emulator). The repo is the *thin web shell around CheerpX*, not the VM itself.

**Boot flow** — all in `src/lib/WebVM.svelte`:
`onMount` → `initTerminal()` (xterm.js + fit/web-links addons) → `initCheerpX()` → dynamic `import('@leaningtech/cheerpx')` → build a block device → wrap with `IDBDevice` (IndexedDB cache) + `OverlayDevice` (copy-on-write over the read-only base image) → assemble a fixed mount table (`/`, `/web`, `/data`, `/dev`, `/dev/pts`, `/proc`, `/sys`, `/home/user/documents`) → `CheerpX.Linux.create({mounts, networkInterface})` → loop `await cx.run(cmd, args, opts)`.

**Disk image backend** is chosen at runtime by `configObj.diskImageType` (a switch in `initCheerpX`), *not* a build flag:
- `cloud` → `CheerpX.CloudDevice` (`wss://`, auto-fallback to `https://`) — the public default.
- `bytes` → `CheerpX.HttpBytesDevice` (a single `.ext2` over HTTP range requests) — used for local/bundled images. **This is the path an offline iOS app would use.**
- `github` → `CheerpX.GitHubDevice` (image split into 128k `.txt` chunks + `index.list` manifests, served from GitHub Pages).

**Cross-origin isolation is mandatory.** CheerpX needs `SharedArrayBuffer`, which requires the page to be cross-origin isolated via headers `COOP: same-origin`, `COEP: require-corp`, `CORP: cross-origin`. Without them the VM does not boot. They are delivered redundantly: `nginx.conf` sets them for local serving; `serviceWorker.js` rewrites them onto every fetch response so static hosts (GitHub Pages) work without server config.

**Networking** is Tailscale-only (`src/lib/network.js`). Browsers have no raw sockets, so CheerpX runs a userspace lwIP TCP/IP stack and tunnels through Tailscale (WireGuard). `authKey`/`controlUrl` are read from the URL hash. No ICMP — use `curl`/`wget` for connectivity checks.

**Build modes** (env vars consumed by `vite.config.js`): `WEBVM_MODE=github` swaps the terminal config to `config_github_terminal.js`; `CX_URL=<url>` aliases the `@leaningtech/cheerpx` import to an alternate CheerpX build.

### Files worth knowing

| File | Role |
| --- | --- |
| `src/lib/WebVM.svelte` | Core runtime — terminal + CheerpX boot, mounts, device selection, display canvas. |
| `config_public_terminal.js` | Default config (Debian, `diskImageType: "cloud"`, `cmd: /bin/bash`). Edit for local serving. |
| `config_public_alpine.js` | Graphical Alpine desktop (`needsDisplay: true`, `cmd: /sbin/init`) → `/alpine` route. |
| `config_github_terminal.js` | Template with `IMAGE_URL/CMD/ARGS/ENV/CWD` placeholders; `sed`-filled by the Deploy workflow. |
| `vite.config.js` | Config-alias + `CX_URL` override; `viteStaticCopy` of `serviceWorker.js`, `login.html`, `assets/`, `documents/`. |
| `serviceWorker.js` | Injects COOP/COEP/CORP on every response (the no-server-config path to cross-origin isolation). |
| `nginx.conf` | Local serving on `:8081` with COI headers + `application/wasm` MIME. |
| `src/lib/network.js` | Tailscale `networkInterface` passed to `CheerpX.Linux.create`. |
| `src/lib/anthropic.js` | In-browser Claude integration (`dangerouslyAllowBrowser`, key in `localStorage`). |
| `.github/workflows/deploy.yml` | Builds the `.ext2` image from a Dockerfile and deploys to GitHub Pages. |
| `dockerfiles/debian_mini`, `debian_large` | i386 Debian Buster rootfs sources for disk images. |

## Common commands

There is **no test or lint suite** — `package.json` defines only `dev` and `build`. Validate changes by building and running locally.

```sh
npm install                      # NOTE: pulls `labs` over SSH (git@github.com:leaningtech/labs.git) — needs SSH access
npm run dev                      # Vite dev server, hot reload
npm run build                    # static export -> build/  (public Debian/Alpine config, npm CheerpX)
WEBVM_MODE=github npm run build  # GitHub Pages mode (config_github_terminal.js)
CX_URL=<url> npm run build       # build against a custom CheerpX deployment
nginx -p . -c nginx.conf         # serve build/ at http://127.0.0.1:8081 with required COI headers
```

**Disk images** are not committed (`custom-disk-images/*` is gitignored). For local use, download an image (e.g. `debian_mini_*.ext2` from the upstream Releases) into `custom-disk-images/`, then in `config_public_terminal.js` set `diskImageUrl` to `/custom-disk-images/<file>.ext2` **and** `diskImageType` to `"bytes"`.

**Building a custom image** (the Deploy workflow's job): build an `--platform=i386` Debian container, `docker inspect` to extract `Cmd/Env/WorkingDir`, `fallocate` + `mkfs.ext2 -r 0` a fixed-size image (default 750M, **950M max**), `docker cp -a` the rootfs in. The Dockerfile `CMD` is load-bearing — it becomes the VM's startup command (change it to `/usr/bin/python3` for a Python REPL). Trigger via `gh workflow run Deploy -f DOCKERFILE_PATH=dockerfiles/debian_mini -f DEPLOY_TO_GITHUB_PAGES=true`.

## Critical constraints / gotchas

- **CheerpX licensing.** Apache-2.0 covers this repo's source, **not** the CheerpX engine. The public CheerpX deployment is free only for individuals/testing; org/commercial use needs a license, and *self-hosting or redistributing a downloaded CheerpX build (e.g. bundling it in an app) is not permitted without a commercial license*. This must be resolved before shipping an App Store binary. See https://cheerpx.io/docs/licensing.
- **CheerpX version pin.** `package.json` pins `@leaningtech/cheerpx: "latest"` (a moving tag); `package-lock.json` resolves it to **1.3.5**. Reproducible builds depend on the lockfile — a fresh unpinned install can pull an incompatible CheerpX.
- **`npm install` needs SSH** to `git@github.com:leaningtech/labs.git`.
- **Build needs network.** `src/routes/+layout.server.js` fetches blog OG metadata from `labs.leaningtech.com` at prerender time; offline/firewalled builds may hang.
- Dockerfiles must be `--platform=i386` (CheerpX is 32-bit x86); the Buster base is EOL and repoints APT to `archive.debian.org`.
- `build/alpine.html` is deleted in the GitHub Pages deploy step, so forks deploying to Pages don't get `/alpine`.
- WebVM officially targets **recent desktop** browsers (`src/lib/messages.js`) — mobile/iOS is not a stated supported target, so SAB/threads/JIT/memory behavior on iOS must be validated, not assumed.

## iOS conversion

Goal: wrap the WebVM static build in a **WKWebView** iOS/iPadOS app and ship via TestFlight. Two sibling repos are the references — read their notes before starting:

- **`../w-shell`** — *started* as exactly this (WebVM/CheerpX in WKWebView) and **abandoned it**, pivoting to a fully native terminal ("Helix Shell"). Do **not** treat its current code as a working WebVM port (the CheerpX path was deleted 2026-06-17). It is, however, the authoritative reference for the WKWebView cross-origin-isolation pattern and the XcodeGen→TestFlight chain.
- **`../goobusters`** — a separate iPad app; its `testflight_push.py` is the cleanest **reusable** build→sign→upload→TestFlight-notes chain.

External prior art for component patterns (study, don't fork): **a-Shell** (the keep-a-hidden-WKWebView-alive-for-JIT pattern; offline tool packaging) and **Blink Shell** (polished iOS terminal UX — keyboard/soft-keyboard handling, fonts/themes, touch gestures, select/copy/paste). Lean on these for the terminal-UX roadmap items below rather than building input/clipboard handling from scratch.

### Working app (`ios/`, verified 2026-06-24)

A minimal, **additive** iOS/iPadOS app in `ios/` boots WebVM to an interactive bash shell in WKWebView and uploads to TestFlight. Build/run:

```sh
cd ios && ./build.sh        # simulator: stage web+disk, xcodegen, build, install+launch
cd ios && ./testflight.sh   # device archive -> sign -> upload to TestFlight (needs ios/.asc.env + the .p8)
# boot trace (crossOriginIsolated, headscale state, disk range-fetches, terminal text):
xcrun simctl spawn booted log show --style compact --last 2m --predicate 'subsystem == "app.ish.iSH.KTGSS9PB3A"'
```

What it is (each file small and single-purpose):
- `ios/App/LocalServer.swift` + `Headers.swift` — Telegraph HTTP server on `127.0.0.1` (fixed port **47821**, ephemeral fallback) serving the bundled web build + disk image with COOP/COEP/CORP on every response, Range/206, `Last-Modified`.
- `ios/App/WasmWebView.swift` — full-screen `WKWebView` (stock config) + a `console.log`→`os_log` bridge; injects `#authKey=…&controlUrl=…` (percent-encoded) into the loaded URL.
- `ios/App/NetworkConfig.swift` — loads preconfigured Headscale `controlUrl`/`authKey` from a bundled `HeadscaleConfig.json` (nil → interactive-login fallback). See [Networking](#networking-preconfigured-headscale).
- `ios/App/ContentView.swift` / `WebVMApp.swift` — start server, gate the web view on the port, loopback `URLSession` self-diagnostic logging the COI headers on the wire.
- `ios/App/Assets.xcassets` — `AppIcon` (1024² opaque tesseract). `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` lets actool inject `CFBundleIconName` (required for TestFlight upload; simulator builds don't need it).
- `ios/project.yml` — single XcodeGen target, bundle **`app.ish.iSH.KTGSS9PB3A`**, team `KTGSS9PB3A`, iOS 17, one remote SwiftPM dep (Telegraph 0.40.0). `WebVM.xcodeproj` generated/gitignored.
- `ios/stage.sh` — `WEBVM_MODE=ios npm run build` → stage `build/` + APFS-clone `custom-disk-images/debian_mini.ext2` into `ios/web/webroot/` (folder reference, gitignored); generate `App/Generated/HeadscaleConfig.json` from `ios/.network.env`.
- `ios/testflight.sh` — stamp timestamp `CFBundleVersion`, archive, on-the-fly `ExportOptions.plist`, `xcodebuild -exportArchive` upload via the `.p8` key (config in gitignored `ios/.asc.env`).
- Fork changes are 2 lines: a `WEBVM_MODE=ios` branch in `vite.config.js` + `config_ios_terminal.js` (`diskImageType:"bytes"`, `/disk/debian_mini.ext2`). Default cloud config untouched.

Verified — **simulator** (iPad Pro 11" M5, iOS 26): `crossOriginIsolated=true`, SAB available, 8 cores; COI headers on the wire; CheerpX engine from `cxrtnc.leaningtech.com` (`CORP: cross-origin`); 600 MB `debian_mini.ext2` range-fetched locally (CheerpX probes size via `Range: bytes=0-1`, so the HEAD route is unused); Debian reached `user@:~$`. **TestFlight**: Release archive signed + uploaded to `app.ish.iSH.KTGSS9PB3A` (build ~300 MB — the ext2 is mostly empty/compressible, so the zipped `.ipa` is ~half; it expands to ~600 MB on install).

Not yet validated (next phases): real-device run (WebKit JIT/memory differ from the Mac-hosted simulator); disk-image size strategy (the ~600 MB image is the core size cost); a live Headscale connection (needs the owner's server + CORS + DERP). A benign `Ignoring Event: localhost` console line appears during boot.

### Architecture decision (the hard-won part)

CheerpX in WKWebView needs `crossOriginIsolated === true` for `SharedArrayBuffer`. The working pattern from `w-shell`:

- Serve the bundled static build from a **local HTTP server on `127.0.0.1:<ephemeral port>`** (w-shell uses the off-the-shelf **Telegraph** Swift package), emitting `COOP: same-origin`, `COEP: require-corp`, `CORP`. A custom `WKURLSchemeHandler` was *not* used; WKWebView service-worker support is too limited to rely on `serviceWorker.js`.
- **`COEP: credentialless` does NOT yield `crossOriginIsolated=true` on iPad WKWebView** (iOS lags Safari) — `require-corp` is load-bearing. Switching away from it silently breaks SAB.
- `require-corp` means **every subresource must be same-origin** (`CORP: cross-origin`) — bundle all assets locally; no CDN/registry loads.
- `Info.plist` needs ATS exceptions for `127.0.0.1`/`localhost` (`NSExceptionAllowsInsecureHTTPLoads` + `NSAllowsLocalNetworking`) since the local server is plain HTTP, plus `NSLocalNetworkUsageDescription`.

### Hard constraints (from w-shell's experience)

- **Disk-image size is the central problem.** A CheerpX `.ext2` (~956 MB) pushed a TestFlight build to ~1.1 GB. Use `diskImageType: "bytes"` with the smallest viable `debian_mini` image; solve on-device storage/download strategy deliberately.
- iOS 17+ floor; **WKWebView only** (no BrowserEngineKit — EU-only); **no background execution** (a suspended app cannot keep a VM running); no remote backend.
- JIT-in-WKWebView: WebAssembly runs inside WebKit (the only App-Store-sanctioned engine). The a-Shell pattern of keeping a hidden WKWebView alive to retain the JIT entitlement may be needed — verify CheerpX's WASM JIT actually runs on the target iOS WebKit.
- Persistence relies on IndexedDB (`IDBDevice`/`OverlayDevice`); confirm WKWebView quota/eviction doesn't drop VM state.
- The terminal variant (`config_public_terminal.js`, `needsDisplay: false`, xterm) is far lighter than the graphical Alpine variant — make it the first iOS target. Touch input + iOS soft keyboard need handling for the canvas/graphical mode.

### Build, signing & TestFlight chain

Both reference repos use **App Store Connect API-key (`.p8`) auth exclusively** — no Apple ID, no app-specific password, no `altool`/`fastlane`/`notarytool`. Reuse the **goobusters `testflight_push.py`** flow (most portable):

1. Stamp `CFBundleVersion` = Unix timestamp in `Info.plist` (guarantees a unique, increasing build number).
2. `xcodebuild archive` (Release, `-sdk iphoneos`, automatic signing, `-allowProvisioningUpdates`).
3. Generate `ExportOptions.plist` on the fly (`method=app-store-connect`, `destination=upload`, `signingStyle=automatic`).
4. `xcodebuild -exportArchive … -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` — exports **and** uploads in one step.
5. Mint an ES256 JWT from the same `.p8` (PyJWT) to set the TestFlight "What to Test" notes via the App Store Connect REST API.

Reusable as-is: timestamp build number, on-the-fly `ExportOptions.plist`, single-key dual-purpose auth, the **`/usr/bin`-first PATH workaround** (Homebrew `rsync` breaks `xcodebuild -exportArchive`), and `ITSAppUsesNonExemptEncryption=false` in `Info.plist` (avoids the export-compliance stall). **Replace** goobusters' `bundle_python.sh` entirely — WebVM has no Python backend; the "bundle" step instead stages the WebVM `build/` dir + a `debian_mini` `.ext2`.

**Implemented** as `ios/testflight.sh` (this flow, minus the JWT "What to Test" notes step) and verified — a Release build uploaded to TestFlight for `app.ish.iSH.KTGSS9PB3A`.

### Build & push: automation user (`sqrlbot`) vs owner (`cseaman`)

Claude runs as OS user **`sqrlbot`**; the human owner is **`cseaman`**. The repo is group-writable (`cseaman:sqrlbot`, `g+w`), so sqrlbot edits/builds/commits directly — but publishing diverges by user:
- **Owner push:** `cd ios && ./testflight.sh` — automatic signing with cseaman's cert, builds in-place. Owner-only (the signing key lives in cseaman's login keychain).
- **sqrlbot push (autonomous):** `ios/tools/push-sqrlbot.sh [branch]` — builds in a **sqrlbot-owned clone** (`~sqrlbot/webvm-push`), **manual-signs** with sqrlbot's *own* self-minted Apple Distribution cert + profile (in the dedicated `webvm-sign` keychain), uploads via the `.p8`. Zero owner involvement. Full setup + gotchas: **`ios/tools/README.md`**.
- **Why two paths:** Xcode *automatic* signing fails for sqrlbot (it finds cseaman's machine Development cert and refuses to recreate without revoking it — never do that); and the owner's `.svelte-kit`/`build` dirs are `755 cseaman`, so sqrlbot can't wipe them to rebuild in place → it builds in a clone instead.
- **Verify any push:** `ios/tools/asc_webvm.py` lists recent builds + `processingState` (`.p8` API auth, works for either user). The `.p8` is API auth only — **not** a signing cert.

### App Store identity

- **Apple Team ID: `KTGSS9PB3A`**.
- **Bundle id: `app.ish.iSH.KTGSS9PB3A`** — the *literal* bundle id (it embeds the team suffix; it is NOT `app.ish.iSH` + a separate team). It maps to the existing **"Placeholder (badmath)"** App Store Connect record, **app id 6754670783**, reused for this project. Confirmed via the ASC API: plain `app.ish.iSH` has no App ID/record, so using it fails export at "Downloading App Information". The chain uploads to the existing record; it does not create apps.
- ASC API key: `~/.appstoreconnect/private_keys/AuthKey_YTYL3XKZXH.p8` (not in repo). Key id / issuer id / team live in gitignored `ios/.asc.env` (copy from `ios/.asc.env.example`); `testflight.sh` sources it. Never commit the `.p8`.
- Signing is fully automatic (`CODE_SIGN_STYLE=Automatic`, `-allowProvisioningUpdates` + the API key). A 1024² opaque app icon (`ios/App/Assets.xcassets/AppIcon`) is mandatory for upload.

### Networking (DirectSockets via on-device relay — IMPLEMENTED, the default)

**The VM reaches the internet straight through the device's own connection — no Tailscale, no Headscale, no relay server, zero extra hops** (chosen for spotty/travel connectivity). This supersedes the Tailscale/Headscale plan for the device-host use case.

Key discovery: CheerpX's engine (`cx_esm.js`) exports a **`DirectSocketsNetwork`** backend (not in the npm `index.d.ts`). If the `networkInterface` passed to `Linux.create` has **no `netmapUpdateCb`** but provides **`TCPSocket(host, port)`** (a WHATWG Direct-Sockets shape), CheerpX routes guest TCP through it instead of Tailscale. Mechanism (ported from w-shell, device-verified):
- `src/lib/net/webvm-net-transport.js` (+ `frame-codec.js`, `_le.js`) — a `networkInterface` whose `TCPSocket` frames each guest connection over a loopback **WebSocket** to `ws://127.0.0.1:47821/net`. `WebVM.svelte` uses it when `configObj.netTransport === "directsockets"` (set in `config_ios_terminal.js`).
- `ios/App/NetBridge.swift` — Telegraph `/net` WS handler → `NWConnection` dials each connection out the device's network and pumps bytes both ways (frame: `op|conn_id(4LE)|len(4LE)|payload`, byte-identical to the JS codec). Wired via `LocalServer`'s `webSocketDelegate`.
- **Egress must use `NWConnection`, not raw POSIX sockets** (those fail `ECONNREFUSED` on-device without `IP_BOUND_IF`) — the load-bearing lesson inherited from w-shell.
- **Verified on simulator (CheerpX 1.3.5):** a full HTTP round-trip — guest `GET` (33 B) → `1.1.1.1:80` via the device → 381 B response back to the VM. TCP egress + bidirectional data confirmed in the native `net` logs (at `os_log` `.info` — capture with `log show --info`).
- **DNS:** UDP is not yet bridged (`UDPSocket` stubbed), so resolution uses **DNS-over-TCP** — `RES_OPTIONS=use-vc` is set in `config_ios_terminal.js` `opts.env`, and `NWConnection` resolves hostnames device-side. Full UDP DNS (a `UDPSocket` bridge) is the remaining polish.

The Tailscale/Headscale path (`src/lib/network.js`, `NetworkConfig.swift`, `HeadscaleConfig.json`, `.network.env`) remains for **tailnet-peer** access (reaching your own machines), selected when `netTransport` is unset; it is not needed for plain internet.

### Feature roadmap (in owner's priority order)

1. ✅ **Boot in WKWebView** — done; see [Working app](#working-app-ios-verified-2026-06-24).
2. ✅ **Internet via device host (no Tailscale)** — DONE & sim-verified via CheerpX DirectSockets + on-device `NWConnection` relay (full HTTP round-trip through the device). See [Networking](#networking-directsockets-via-on-device-relay--implemented-the-default). Remaining polish: UDP-socket bridge for native UDP DNS (TCP DNS works today via `use-vc`).

Later (larger) requests:

3. ~~**Map the VM home directory to the iOS app's Documents folder**~~ — **BLOCKED (researched + spiked 2026-07-07, owner call).** The VM's fs is a native black box: `$HOME` lives in the ext2/Overlay block image (opaque to JS and native; WKWebView IndexedDB is natively unreadable — verified experimentally). A writable `IDBDevice` dir-mount at `/home/user/documents` *works* (guest r/w, relaunch persistence, full host↔guest file round-trip all sim-verified), but **exec-ing any file on such a mount wedges the VM uninterruptibly** — a CheerpX 1.3.5 engine bug (`promoteReadToExec` r→x promotion passes execve into a cxcore.wasm loader hang; 1.3.5 is the latest engine anywhere). A page-side noexec shim (a `Worker.prototype.postMessage` wrapper stripping the promotion) defuses the default case (`./x.sh` → clean EACCES; `bash x.sh` works) but `chmod +x f && ./f` in-session still wedges — the worker-side inode is unreachable from the page. A FileProvider extension can't rescue it (extensions can neither read WKWebView IDB nor run the VM). Revisit only if Leaning Tech fixes the exec path. Full trail: `docs/research/2026-07-07-home-documents-blocked.md`.
4. **Status bar made lighter weight** (the WebVM sidebar/top chrome) — UX trim for a mobile-first layout.
5. **Fonts and colors** — xterm.js theme/font configuration (see Blink Shell for reference UX).
6. **Improved select / copy / paste + mouse/touch pass-through** — bridge iOS touch + clipboard to xterm.js (terminal) and the KMS canvas (graphical). Study Blink/a-Shell here.
