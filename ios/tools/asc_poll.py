# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]>=2.8", "requests>=2.31"]
# ///
"""Poll App Store Connect until the target TestFlight build surfaces, then exit.
Prints one status line per check and a final line when it lands (or times out)."""
import os, time, sys, jwt, requests

ASC_ENV = "/Users/cseaman/projects/webvm/ios/.asc.env"
APP_ID = "6754670783"
TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 0        # build number to wait for (usage: asc_poll.py <build> [baseline])
BASELINE = int(sys.argv[2]) if len(sys.argv) > 2 else (TARGET - 1 if TARGET else 0)  # only builds strictly above count as "new"
INTERVAL = 90
MAX_MIN = 20

def load_env(path):
    env = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

env = load_env(ASC_ENV)
kid, iss = env["ASC_KEY_ID"], env["ASC_ISSUER_ID"]
private_key = open(f"/Users/sqrlbot/.appstoreconnect/private_keys/AuthKey_{kid}.p8").read()

def check():
    now = int(time.time())
    tok = jwt.encode({"iss": iss, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                     private_key, algorithm="ES256", headers={"kid": kid, "typ": "JWT"})
    r = requests.get("https://api.appstoreconnect.apple.com/v1/builds",
                     headers={"Authorization": f"Bearer {tok}"},
                     params={"filter[app]": APP_ID, "sort": "-uploadedDate", "limit": "5",
                             "fields[builds]": "version,processingState,uploadedDate"}, timeout=30)
    if r.status_code != 200:
        return None, f"HTTP {r.status_code}"
    for b in r.json().get("data", []):
        a = b["attributes"]
        try:
            v = int(a.get("version", "0"))
        except ValueError:
            continue
        if v > BASELINE:
            return (v, a.get("processingState", "?"), (a.get("uploadedDate") or "")[:19]), None
    return None, "not-yet"

deadline = time.time() + MAX_MIN * 60
i = 0
while time.time() < deadline:
    i += 1
    found, note = check()
    if found:
        v, state, up = found
        tag = "TARGET" if v == TARGET else f"new (expected {TARGET})"
        print(f"LANDED: build {v} [{tag}] state={state} uploaded={up}Z", flush=True)
        sys.exit(0)
    print(f"check #{i}: no new build yet ({note}); newest still <= {BASELINE}", flush=True)
    time.sleep(INTERVAL)

print(f"TIMEOUT after {MAX_MIN}min: build {TARGET} never surfaced on ASC — upload likely did not complete.", flush=True)
sys.exit(1)
