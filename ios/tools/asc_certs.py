# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]>=2.8", "requests>=2.31"]
# ///
"""List the Apple Developer account's signing certificates (type, name, expiry)
so we can judge whether minting a dedicated sqrlbot cert via the API is viable
vs. importing an exported .p12. Read-only."""
import time, jwt, requests

ASC_ENV = "/Users/cseaman/projects/webvm/ios/.asc.env"
def load_env(p):
    e = {}
    for l in open(p):
        l = l.strip()
        if l and not l.startswith("#") and "=" in l:
            k, v = l.split("=", 1); e[k.strip()] = v.strip().strip('"').strip("'")
    return e
env = load_env(ASC_ENV)
kid, iss = env["ASC_KEY_ID"], env["ASC_ISSUER_ID"]
pk = open(f"/Users/sqrlbot/.appstoreconnect/private_keys/AuthKey_{kid}.p8").read()
now = int(time.time())
tok = jwt.encode({"iss": iss, "iat": now, "exp": now+600, "aud": "appstoreconnect-v1"},
                 pk, algorithm="ES256", headers={"kid": kid, "typ": "JWT"})
r = requests.get("https://api.appstoreconnect.apple.com/v1/certificates",
                 headers={"Authorization": f"Bearer {tok}"},
                 params={"limit": "50", "fields[certificates]": "certificateType,displayName,expirationDate"},
                 timeout=30)
if r.status_code != 200:
    print(f"HTTP {r.status_code}: {r.text[:300]}"); raise SystemExit(1)
data = r.json().get("data", [])
from collections import Counter
counts = Counter(c["attributes"].get("certificateType", "?") for c in data)
print(f"{'TYPE':<26} {'NAME':<40} EXPIRES")
print("-"*82)
for c in sorted(data, key=lambda x: x["attributes"].get("certificateType","")):
    a = c["attributes"]
    print(f"{a.get('certificateType','?'):<26} {(a.get('displayName') or '')[:40]:<40} {(a.get('expirationDate') or '')[:10]}")
print("-"*82)
print("counts by type:", dict(counts))
print("(Apple caps DISTRIBUTION/IOS_DISTRIBUTION certs ~2-3 per account; DEVELOPMENT is generous)")
