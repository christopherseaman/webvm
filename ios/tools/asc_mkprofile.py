# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]>=2.8", "requests>=2.31"]
# ///
"""Create + install an App Store distribution provisioning profile bound to
sqrlbot's own distribution cert, so xcodebuild can sign manually with it."""
import base64, os, time, sys, jwt, requests

ASC_ENV = "/Users/cseaman/projects/webvm/ios/.asc.env"
BUNDLE = "app.ish.iSH.KTGSS9PB3A"
CERT_ID = "Y35B647T8S"
PROFILE_NAME = "WebVM sqrlbot AppStore"
PROFILES_DIR = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")

def env(p):
    e = {}
    for l in open(p):
        l = l.strip()
        if l and not l.startswith("#") and "=" in l:
            k, v = l.split("=", 1); e[k.strip()] = v.strip().strip('"').strip("'")
    return e
e = env(ASC_ENV)
p8 = open(f"/Users/sqrlbot/.appstoreconnect/private_keys/AuthKey_{e['ASC_KEY_ID']}.p8").read()
def tok():
    n = int(time.time())
    return jwt.encode({"iss": e["ASC_ISSUER_ID"], "iat": n, "exp": n+600, "aud": "appstoreconnect-v1"},
                      p8, algorithm="ES256", headers={"kid": e["ASC_KEY_ID"], "typ": "JWT"})
def H(): return {"Authorization": f"Bearer {tok()}", "Content-Type": "application/json"}

# bundleId ASC id — filter[identifier] is a CONTAINS match, so pick the EXACT one
r = requests.get("https://api.appstoreconnect.apple.com/v1/bundleIds", headers=H(),
                 params={"filter[identifier]": BUNDLE, "limit": "200",
                         "fields[bundleIds]": "identifier"}, timeout=30)
r.raise_for_status()
exact = [b for b in r.json()["data"] if b["attributes"]["identifier"] == BUNDLE]
if not exact:
    print(f"no EXACT bundleId record for {BUNDLE}", file=sys.stderr); sys.exit(1)
bundle_id = exact[0]["id"]
print(f"bundleId {BUNDLE} -> {bundle_id} (exact)", flush=True)

# delete any existing profile of the same name (idempotent re-runs)
r = requests.get("https://api.appstoreconnect.apple.com/v1/profiles", headers=H(),
                 params={"filter[name]": PROFILE_NAME, "limit": "10"}, timeout=30)
for p in r.json().get("data", []):
    requests.delete(f"https://api.appstoreconnect.apple.com/v1/profiles/{p['id']}",
                    headers={"Authorization": f"Bearer {tok()}"}, timeout=30)
    print(f"  removed existing profile {p['id']}", flush=True)

# create the App Store profile bound to our cert
r = requests.post("https://api.appstoreconnect.apple.com/v1/profiles", headers=H(),
                  json={"data": {"type": "profiles",
                                 "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
                                 "relationships": {
                                     "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                                     "certificates": {"data": [{"type": "certificates", "id": CERT_ID}]}}}},
                  timeout=30)
if r.status_code not in (200, 201):
    print(f"profile create FAILED HTTP {r.status_code}: {r.text[:500]}", file=sys.stderr); sys.exit(1)
a = r.json()["data"]["attributes"]
uuid = a["uuid"]
content = base64.b64decode(a["profileContent"])
os.makedirs(PROFILES_DIR, exist_ok=True)
path = os.path.join(PROFILES_DIR, f"{uuid}.mobileprovision")
with open(path, "wb") as f:
    f.write(content)
print(f"created + installed profile:")
print(f"  name={PROFILE_NAME}  uuid={uuid}")
print(f"  -> {path}")
print(f"PROFILE_UUID={uuid}")
