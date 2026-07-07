# sqrlbot → TestFlight: autonomous publishing

How the `sqrlbot` automation user (the account Claude runs as) can build, sign, and
upload WebVM TestFlight builds with **zero input from the owner** — one command:
`ios/tools/push-sqrlbot.sh`.

## Why this needed setup

Claude runs as OS user **`sqrlbot`**; the human owner is **`cseaman`**. TestFlight
signing needs an **Apple Distribution certificate + its private key** in a keychain the
signing process can open — and that key lived only in cseaman's login keychain,
unreachable across users. Copying the `.p8` API key doesn't help: the `.p8` is API
*auth* (profiles + upload), not a signing certificate.

Xcode's **automatic** signing can't bridge this for sqrlbot either — it detects
cseaman's existing machine Development cert, sees sqrlbot lacks its key, and refuses to
create a new one *"without revoking your existing certificate"* (which would break
cseaman's own signing). So automatic signing is a dead end here.

**Solution:** give sqrlbot its *own* signing identity, created directly through the
App Store Connect API, and sign **manually**. Nothing of the owner's is touched or revoked.

## The pieces (one-time setup, already done)

| Piece | What / where | Created by |
| --- | --- | --- |
| Dedicated keychain | `webvm-sign.keychain` (password in `~sqrlbot/.webvm-sign-kc.pw`, mode 600); set as default + first in search list, no auto-lock | `security create-keychain …` |
| sqrlbot's Apple Distribution cert | `Y35B647T8S` — key generated locally, cert issued via ASC API `POST /v1/certificates`; key lives only in `webvm-sign` | `ios/tools/asc_mkcert.py` |
| WWDR-G3 intermediate | imported so the leaf chains to Apple Root (from Xcode's `…/DVTFoundation.framework/…/AppleWWDRCA-2030.cer`; Apple's download URLs 404) | `security import` |
| App Store profile | `WebVM sqrlbot AppStore`, bound to the exact bundle id record + the cert; installed to `~/Library/MobileDevice/Provisioning Profiles/` | `ios/tools/asc_mkprofile.py` |
| Publisher | `ios/tools/push-sqrlbot.sh` | — |

## How publishing works (`push-sqrlbot.sh`)

1. **Refresh** a sqrlbot-owned clone at `~sqrlbot/webvm-push` from the real repo's
   branch (sidesteps the real repo's cseaman-owned `.svelte-kit`/`build` dirs, which
   sqrlbot can't wipe to rebuild).
2. **Provision deps**: APFS-clone `node_modules` + the disk image, copy `.asc.env` /
   `.network.env`.
3. **Build**: unlock `webvm-sign`, `stage.sh` (builds the web bundle clean), `xcodegen`,
   stamp a unix-timestamp `CFBundleVersion`.
4. **Archive** Release with **manual** signing: `CODE_SIGN_STYLE=Manual`,
   `CODE_SIGN_IDENTITY="Apple Distribution"`, `PROVISIONING_PROFILE_SPECIFIER="WebVM sqrlbot AppStore"`.
5. **Export + upload** (app-store-connect) via the `.p8` key.

```sh
ios/tools/push-sqrlbot.sh [branch]      # default branch: ios-app
ios/tools/asc_webvm.py                  # verify: lists recent builds + processingState
```

First proven run: build `1783404329` (the touch-selection fix) went `VALID` on TestFlight,
built + signed + uploaded entirely by sqrlbot.

## Gotchas (each cost real time — avoid)

- **Automatic signing** → *"Revoke certificate"* error for sqrlbot. Use manual + sqrlbot's own cert.
- **ASC `filter[identifier]` is a *contains* match** — `app.ish.iSH.KTGSS9PB3A` also matches
  `app.ish.iSH.KTGSS9PB3A.KTGSS9PB3A`. Pick the record whose identifier is *exactly* the bundle id,
  or the profile's app-id won't match (`…KTGSS9PB3A.KTGSS9PB3A` mismatch at archive).
- **macOS `security import` rejects modern PKCS#12** (`MAC verification failed`). Build the `.p12`
  with legacy `PBESv1SHA1And3KeyTripleDESCBC` + SHA-1 HMAC.
- **Missing WWDR-G3 intermediate** → `find-identity -v` shows `0 valid`. Import Xcode's `AppleWWDRCA-2030.cer`.
- When scripting cert creation, **revoke-on-failure** or orphan distribution certs pile up against Apple's cap.

## Maintenance

- Cert `Y35B647T8S` + profile expire **2027-07-07**. Recreate with `ios/tools/asc_mkcert.py` then
  `ios/tools/asc_mkprofile.py`.
- To remove sqrlbot's identity entirely: delete the cert + profile in App Store Connect (or via API).
  The owner's own cert is separate and unaffected.
- `.p8` API key: `~sqrlbot/.appstoreconnect/private_keys/AuthKey_YTYL3XKZXH.p8` (auth only).

## Not touched

cseaman's certificate, keychain, and signing setup are untouched. sqrlbot's cert + profile are
**additive** on the account and **revocable** at any time.
