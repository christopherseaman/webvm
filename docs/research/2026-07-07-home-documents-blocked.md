# VM home dir ↔ iOS Documents: research synthesis and recommendation

## 1. How the filesystem stack works today

- **Root FS is opaque blocks, not files.** `/` = ext2 image (`/disk/debian_mini.ext2`) via `HttpBytesDevice`, wrapped in `OverlayDevice` whose copy-on-write layer is `IDBDevice.create("blocks_terminal")` — block-level records in IndexedDB. `$HOME=/home/user` lives inside this image; no JS or native API can read files out of it (`src/lib/WebVM.svelte:650-681`, `src/routes/+page.svelte:15`, `config_ios_terminal.js`).
- **The only "shared folder" hook is read-only.** `/home/user/documents` = `WebDevice.create("documents")`, an HTTP-GET-only device (engine sets `writeAsync=null`, open fails for any mode ≠ `r`; listings require `index.list`). On iOS it serves the static sample files baked into the signed bundle at `http://127.0.0.1:47821/documents/` (`WebVM.svelte:662,680`; cheerpOS.js `WebOps`; `vite.config.js:24`, `ios/stage.sh`).
- **Only three device types are host-accessible from page JS**: WebDevice (guest-RO), DataDevice (host-write/guest-RO, in-memory), IDBDevice (full guest read-write, persistent, host-readable via `readFileAsBlob(path)`). Block devices (HttpBytes/Overlay/File) have no file API (`index.d.ts`; cheerpx.io File-System-support guide).
- **Native serving/bridge infrastructure already exists.** Telegraph on fixed port 47821 serves the bundle with COI headers + Range/206 (`ios/App/LocalServer.swift`, `Headers.swift`); a device-verified framed WS byte channel (`/net`) connects JS to `NWConnection` (`ios/App/NetBridge.swift`, `src/lib/net/*`); plus a lightweight `WKScriptMessageHandler` channel (`ios/App/WasmWebView.swift`). Note: on this branch `netTransport` is unset, so the JS side of `/net` is dormant — only the Swift demux is live (`config_ios_terminal.js:7`).
- **The Files-app half is already done.** `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` are set (`ios/App/Info.plist:23-24,51-52`); Documents is currently empty. The whole problem reduces to moving bytes between Documents and a VM-visible mount.
- **Persistence caveats**: IndexedDB is keyed to origin *including port* — the ephemeral-port fallback silently orphans all VM state (`LocalServer.swift:17-20`; verified 5 port-origins in the simulator container). Sidebar "Reset" wipes `blocks_terminal` (`WebVM.svelte:736-743`), so a share must use its own devName.

## 2. Candidate architectures

### A. Telegraph-served Documents → WebDevice mount (live, read-only into VM)

- **Mechanism**: Add a Telegraph route serving the real Documents dir (second root beside `webroot`), synthesizing `index.list` per directory on request; point `WebDevice.create()` at it. Zero engine changes; LocalServer already does Range/206 + Last-Modified.
- **Coverage**: iOS→VM only, read-only, "live-ish". VM→iOS: none. Staleness risk: WebDevice caches inode/length/128KB chunks per file after first stat, so mid-session host edits are not re-read (cheerpOS.js `CheerpJWebFolder.inodeMap`).
- **Effort**: **S** (a route + a listing generator + one mount-URL change).
- **Risks/unknowns**: whether `index.list` is re-fetched per directory access or cached for the session.
- **30-min spike**: add the route, boot, `ls`/`cat` in guest, add + edit a file host-side, observe what the guest sees.

### B. IDBDevice share mount + sync daemon over existing channels — **recommended**

- **Mechanism**: Replace the documents WebDevice with `IDBDevice.create("share_docs")` mounted `{type:"dir", path:"/home/user/documents"}` (separate devName so Reset doesn't wipe it). Guest gets a real read-write directory; symlink from `$HOME` for convenience.
  - **VM→iOS**: `cheerpOSWatchFiles(prefix, cb)` fires on every guest file commit (undocumented but verified in cheerpOS.js 1.3.5: `idbCommitFileData`/`idbUnlinkAsync` call `cheerpOSWatchNotify`); on event, `readFileAsBlob(path)` (documented) and POST the bytes to a new Telegraph route (or a `/fs` WS endpoint cloning the `/net` codec); Swift writes them into Documents. `cheerpOSListFiles` exists for full enumeration (gap-check verified), so no guest-written manifest needed.
  - **iOS→VM**: native detects Documents changes (dispatch source / on-foreground scan) → `evaluateJavaScript` → `DataDevice.writeFile(path, Uint8Array)` (binary-safe, gap-check verified) + guest `cp`, or host-driven `CheerpX.copyFile({dev:dataDev,...},{dev:idbDev,...})` (undocumented) to skip the guest hop.
- **Coverage**: both directions. VM→iOS is event-driven near-live; iOS→VM is sync-on-change/foreground (VFS cache coherence for host-injected files is unverified — worst case, inbound is "visible after next lookup or remount").
- **Effort**: **M** (mount swap ~5 lines; one Telegraph route; a ~150-line JS sync module; a small Swift Documents writer/watcher).
- **Risks/unknowns**: whole-file model — each file is committed as one contiguous `Uint8Array` (memory ceiling for large files unmeasured); no chmod handler found in the JS FS layer (create-time modes persist, later `chmod` may no-op → ssh keys/exec bits suspect → argues for a shared *subdir*, not whole-`$HOME`, which is unreachable anyway); WKWebView IDB quota/eviction unmeasured; 2 GiB device cap; `cheerpOSWatchFiles`/`copyFile` are undocumented, pinned to CheerpX 1.3.5. Degradation path is graceful: without the undocumented pieces it collapses to the fully-documented explicit sync (`DataDevice.writeFile` in, guest-copy + `readFileAsBlob` out — the vendor's own pattern, cheerpx.io input-output guide; WakkaCode prior art).
- **30-min spike**: see §3.

### C. Native-side sync against the IndexedDB sqlite

- **Mechanism**: Swift reads/writes WKWebView's `IndexedDB.sqlite3` directly to mirror a dir-mounted IDBDevice (or the overlay) into Documents.
- **Coverage**: theoretically both directions, offline-capable.
- **Effort**: **L**, and effectively **ruled out**: stock sqlite3 cannot even prepare queries (WebKit-internal `IDBKEY` collation), values are `SerializedScriptValue` blobs, the DB is WAL-locked by WebKit while running, and for the overlay DB the payload is CheerpX's closed block cache, not files (verified experimentally on the simulator container). No supported native API exists (`WKWebsiteDataStore` can only delete). Keep only as a hypothetical last-resort *offline* exporter; do not build on it.
- **Spike**: none warranted — the disqualifying evidence is already experimental.

### D. True live host mount: custom cheerpOS dir-device bridged to native (w-shell 9P resurrection)

- **Mechanism**: Implement the undocumented `mountOps`/`inodeOps` contract from cheerpOS.js as a JS device whose ops RPC over a `/fs` WS endpoint to Swift `FileManager` on Documents — a real mount, no IndexedDB middleman. w-shell built exactly this (9P2000.L server + `webvm-9p-mount.js`, recoverable at `git show 483e4ae` in `../w-shell`).
- **Coverage**: both directions, fully live — the ideal end state.
- **Effort**: **L** (protocol + Swift server + device shim; most code resurrectable).
- **Risks/unknowns**: w-shell's attempt **hung `Linux.create` undiagnosed** on CheerpX 1.2.11 (handshake OK, then silence); the contract is undocumented, closed-source, version-fragile; reverse-engineering/shimming the engine may brush the CheerpX license; the diagnostic plan (log which op CheerpX probes first, verify `CheerpOSDevice` inheritance via `setBaseClass`) was never executed.
- **30-min spike**: mount a stub device on 1.3.5 whose every op logs and returns ENOENT; see whether `Linux.create` completes and which ops fire. Also worth one Discord question to Leaning Tech about the dir-device contract before investing.

## 3. Recommendation

**Build B (IDBDevice share at `/home/user/documents` + sync over the existing Telegraph/WS channels), optionally keeping A's dynamic-listing trick as a later read-only extra.** B is the only option whose foundation is documented, guest-writable, and persistent, and it delivers both directions with effort M using bridge patterns already device-verified in this repo. Its undocumented dependencies (`cheerpOSWatchFiles`, `copyFile`) only buy liveness — if a CheerpX bump breaks them, the design degrades to the vendor-sanctioned explicit sync rather than collapsing. C is experimentally disproven, A is one-directional and stale-prone, and D is blocked on an undiagnosed engine hang plus a closed contract — worth a cheap probe and a vendor question, not the critical path. Mapping literal `$HOME` is off the table regardless (ext2 is opaque); a shared subdir plus a `$HOME` symlink is the achievable granularity.

**First validation spike (~1 hr, the gap-check "decisive un-run spike")**: on the iOS simulator build, mount `IDBDevice.create("share_docs")` as `{type:"dir"}` at `/home/user/documents` (shadowing the populated ext2 dir), then from the guest run write/mkdir/rename/unlink/symlink/exec-bit/chmod-after-create tests, and from the page console verify `readFileAsBlob`, `cheerpOSListFiles`, and `cheerpOSWatchFiles` reach the same files. Every architecture decision downstream depends on this and it currently has zero runtime evidence — all IDB-writability claims are static code reading.

## 4. Open questions the spike must answer

1. **Mount shadowing**: does a `dir` mount at `/home/user/documents` (over a populated ext2 dir) boot and behave? (Also try `/home/user` once, expecting failure/weirdness — settles the "subdir + symlink" framing.)
2. **Path namespace**: is guest `/home/user/documents/foo.txt` addressed as `readFileAsBlob("/foo.txt")` (device-relative) — pinning the sync module's path mapping?
3. **Permissions fidelity**: do create-time modes (exec bit, 600) persist across close + re-stat, and does guest `chmod` after create error, no-op, or persist? Determines whether the share can hold dotfiles/keys or only data files.
4. **Undocumented-global reachability**: `typeof window.cheerpOSWatchFiles/cheerpOSListFiles === "function"` in the real iOS WKWebView build, and does a watch callback fire on guest file close?
5. **Inbound coherence**: with the guest shell idle in the mounted dir, inject a file host-side (`CheerpX.copyFile` or `DataDevice`+copy) — does `ls` see it without remount (i.e., does the closed WASM VFS cache dentries/negative lookups above the verified cache-free JS layer)?
6. **Deferred but flagged for follow-up measurement, not this spike**: whole-file memory ceiling on WKWebView (large Documents files), IDB quota/eviction + `navigator.storage.persist()`, suspend/kill durability of pending commits, and guarding the ephemeral-port fallback that silently orphans all persisted state.
---

## 5. SPIKE RESULTS (2026-07-07, simulator, CheerpX 1.3.5, 3 runs)

Mounted `IDBDevice.create("share_docs")` as `{type:"dir"}` at `/home/user/documents`, guest test battery at login + page-side probes.

| Question | Verdict | Evidence |
|---|---|---|
| Mount shadowing (dir mount over populated ext2 dir) | ✅ WORKS | boots; `cd` lands; ext2 contents shadowed |
| Guest data ops (write/mkdir/rename/symlink/unlink) | ✅ ALL OK | run-1 markers |
| **Persistence across app relaunch** | ✅ **CONFIRMED** | run-2 saw run-1's `d/r.txt` |
| Host reads guest files | ✅ `readFileAsBlob`, **device-relative** paths (`/d/r.txt`, not absolute) | size matched |
| Host stages inbound | ✅ `DataDevice.writeFile` OK | run-2/3 |
| chmod on share | ✅ rc=0 (exit clean; mode-persistence untested — moot, see below) | run-3 S2 |
| **Exec FROM the share** | ❌ **UNINTERRUPTIBLE GUEST HANG** — `./x.sh` wedges the shell; `timeout -k` cannot kill it | run-2 stall + run-3 S3 (2×) |
| `cheerpOSWatchFiles` events | ❌ never fire for the dir-mount (3 prefixes, write demonstrably after registration) | run-3 |
| `cheerpOSListFiles` | ❌ mount resolution fails (`mount.mountPoint` null, all call shapes) | run-2 |
| `CheerpX.copyFile` | ❌ does not exist on the 1.3.5 module | run-1 |

**Net architecture verdict: B stands, in its documented/degraded form.** The share is a
**data-files-only** directory (never exec from it — and never mount it over anything on `$PATH`);
VM→iOS liveness comes from **polling + a guest-written manifest** (no watch hook); iOS→VM inbound
via `DataDevice.writeFile` + a guest `cp` agent (last leg still to verify — S3 hang blocked it, but
every piece is documented). Full round-trip test = first task of the build phase.

## 6. NOEXEC SHIM SPIKE (run 5, fresh sim, 2026-07-07)

Root cause of the exec hang (agent dissection of cheerpOS.js + cx_pretty.js): CheerpX force-promotes
r→x on dir-device lookups (`promoteReadToExec` in the worker lookup-reply message), so execve passes
into a loader path inside cxcore.wasm that wedges for IDB-backed files (all engine error paths are
silent `debugger` no-ops → vCPU parks forever → uninterruptible).

**Fix: a ~10-line page-side `Worker.prototype.postMessage` wrapper** that zeroes `promoteReadToExec`
and masks x-bits (S_IFREG only) on dir-device lookup replies → the kernel's own execve check returns
EACCES. No engine modification (license-safe), installed before `Linux.create`.

Verified (run 5): `./x.sh` → instant `Permission denied` rc=126 (was: unrecoverable hang);
`bash x.sh` → runs fine; read/write untouched; **full inbound round-trip proven**
(`DataDevice.writeFile` → guest `cp /data/inbox.txt` → share → `readFileAsBlob` reads it back, 18 B).

**Residual hole (confirmed):** `chmod +x f && ./f` in the SAME session still wedges — chmod updates
the worker-side kernel inode, unreachable from the page; after relaunch the shim re-masks stored
x-bits. Scope: deliberate two-step action only; the accidental case is fully defused. Mitigation:
document as a noexec share + report the engine bug to Leaning Tech (3-line repro).
