# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project intent

This is a **fork** of [leaningtech/webvm](https://github.com/leaningtech/webvm) (`origin` = `christopherseaman/webvm`, `upstream` = `leaningtech/webvm`). WebVM is a browser-based x86 Linux VM. The active goal of this fork is to **ship WebVM as an iOS/iPadOS app** (WKWebView wrapper) and distribute it via TestFlight. See [iOS conversion](#ios-conversion) below — that work does not live in this repo yet.

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

### Working spike (verified 2026-06-24)

A minimal, **additive** spike in `ios/` boots WebVM to an interactive bash shell in WKWebView on the iPad simulator. Build/run it:

```sh
cd ios && ./build.sh   # stages web+disk, xcodegen, builds, installs+launches on the booted simulator
# boot trace (crossOriginIsolated, disk range-fetches, terminal text):
xcrun simctl spawn booted log show --style compact --last 2m --predicate 'subsystem == "app.ish.iSH"'
```

What it is (each file is small and single-purpose):
- `ios/App/LocalServer.swift` + `Headers.swift` — Telegraph HTTP server on `127.0.0.1:<ephemeral>`, serving the bundled web build + disk image with COOP/COEP/CORP on every response, Range/206, and `Last-Modified`.
- `ios/App/WasmWebView.swift` — full-screen `WKWebView` (stock config) + a `console.log`→`os_log` bridge that reports `crossOriginIsolated`/SAB and samples terminal text.
- `ios/App/ContentView.swift` / `WebVMApp.swift` — start server, gate the web view on the port, plus a loopback `URLSession` self-diagnostic that logs the COI headers actually on the wire.
- `ios/project.yml` — single XcodeGen target, bundle `app.ish.iSH`, team `KTGSS9PB3A`, iOS 17, one remote SwiftPM dep (Telegraph 0.40.0). `WebVM.xcodeproj` is generated/gitignored.
- `ios/stage.sh` — `WEBVM_MODE=ios npm run build` → stage `build/` + APFS-clone `custom-disk-images/debian_mini.ext2` into `ios/web/webroot/` (folder reference, gitignored).
- Fork changes are 2 lines: a `WEBVM_MODE=ios` branch in `vite.config.js` and a new `config_ios_terminal.js` (`diskImageType:"bytes"`, `/disk/debian_mini.ext2`). The default cloud config is untouched.

Verified on simulator (iPad Pro 11" M5, iOS 26): `crossOriginIsolated=true`, `SharedArrayBuffer` available, 8 cores; COI headers confirmed on the wire; CheerpX engine loaded from `cxrtnc.leaningtech.com` (CDN sends `CORP: cross-origin`); the 600 MB `debian_mini.ext2` range-fetched from the local server (CheerpX probes size via `Range: bytes=0-1`, so the HEAD route is unused); Debian reached an interactive `user@:~$` prompt.

Not yet validated (next phases, not blockers to feasibility): real-device run (WebKit JIT/memory limits differ from the Mac-hosted simulator); the disk-image size strategy for an App-Store binary (600 MB–2 GB is the core shipping problem); code signing / TestFlight upload; the CheerpX redistribution license. A benign `Ignoring Event: localhost` console line appears during boot (cosmetic).

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

### App Store identity

- **Apple Team ID: `KTGSS9PB3A`** (shared across w-shell and goobusters).
- **Designated bundle id for this project: `app.ish.iSH`** (under team `KTGSS9PB3A`) — per the project owner, an unused/dormant placeholder record to reuse. (w-shell's notes describe `app.ish.iSH` as a dormant "Placeholder (badmath)" probe; the owner has assigned it to this project. The app record must already exist in App Store Connect — the upload chain does not create it.)
- ASC API key lives at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` (not in any repo). Key id + issuer id are configured in `goobusters/dot.yaml` (`app_store` block) and `w-shell/tools/build-ios.sh` — read them from there; never commit the `.p8`.
- Signing is fully automatic (`CODE_SIGN_STYLE=Automatic`, `-allowProvisioningUpdates`); add an `.entitlements` file only if WebVM needs a capability the references don't (e.g. JIT/local-network specifics).

### Feature roadmap (in owner's priority order)

1. **Successful boot** in WKWebView (the gate everything else depends on — cross-origin isolation + CheerpX JIT working on-device).
2. **Preconfigured local Headscale** for networking (replacing the interactive Tailscale login). The plumbing already exists — `src/lib/network.js` reads `controlUrl` (and `authKey`) from the URL hash and passes them into `CheerpX.Linux.create`; the README documents Headscale as a supported self-hosted control server. The elegant path is to **inject a fixed `controlUrl`/`authKey` pointing at a bundled/local Headscale** via the native wrapper, not to write new networking code. Note the README's Headscale CORS-proxy requirement and re-evaluate it for the local-server origin.

Later (larger) requests:

3. **Map the VM home directory to the iOS app's Documents folder** — there is already a `WebDevice` mounted at `/home/user/documents`; investigate extending that (or the iOS `UIFileSharingEnabled` Documents dir) so VM `$HOME` ↔ app Documents.
4. **Status bar made lighter weight** (the WebVM sidebar/top chrome) — UX trim for a mobile-first layout.
5. **Fonts and colors** — xterm.js theme/font configuration (see Blink Shell for reference UX).
6. **Improved select / copy / paste + mouse/touch pass-through** — bridge iOS touch + clipboard to xterm.js (terminal) and the KMS canvas (graphical). Study Blink/a-Shell here.
