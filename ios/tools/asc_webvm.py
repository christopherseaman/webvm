# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]>=2.8", "requests>=2.31"]
# ///
"""List recent TestFlight builds for the WebVM app + processing state, via the
App Store Connect API (JWT auth from the .p8 key — no code-signing involved)."""
import os, time, sys, jwt, requests

ASC_ENV = "/Users/cseaman/projects/webvm/ios/.asc.env"
APP_ID = "6754670783"  # app.ish.iSH.KTGSS9PB3A record
BASELINE = 1783365177  # the last-known build; anything above is new this session

def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env

env = load_env(ASC_ENV)
kid, iss = env["ASC_KEY_ID"], env["ASC_ISSUER_ID"]
key_path = f"/Users/sqrlbot/.appstoreconnect/private_keys/AuthKey_{kid}.p8"
with open(key_path) as f:
    private_key = f.read()

now = int(time.time())
token = jwt.encode(
    {"iss": iss, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
    private_key, algorithm="ES256", headers={"kid": kid, "typ": "JWT"},
)
H = {"Authorization": f"Bearer {token}"}

r = requests.get(
    f"https://api.appstoreconnect.apple.com/v1/builds",
    headers=H,
    params={
        "filter[app]": APP_ID,
        "sort": "-uploadedDate",
        "limit": "8",
        "fields[builds]": "version,processingState,uploadedDate,expired,usesNonExemptEncryption",
    },
    timeout=30,
)
if r.status_code != 200:
    print(f"HTTP {r.status_code}: {r.text[:400]}", file=sys.stderr)
    sys.exit(1)

builds = r.json().get("data", [])
if not builds:
    print("No builds found for the app record.")
    sys.exit(0)

print(f"{'BUILD':>12}  {'STATE':<12}  {'UPLOADED (UTC)':<20}  NOTE")
print("-" * 70)
for b in builds:
    a = b["attributes"]
    ver = a.get("version", "?")
    state = a.get("processingState", "?")
    up = (a.get("uploadedDate") or "")[:19].replace("T", " ")
    note = ""
    try:
        if int(ver) > BASELINE:
            note = "← NEW this session"
    except ValueError:
        pass
    if a.get("expired"):
        note += " (expired)"
    print(f"{ver:>12}  {state:<12}  {up:<20}  {note}")
