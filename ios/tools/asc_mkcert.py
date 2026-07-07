# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]>=2.8", "requests>=2.31", "cryptography>=42"]
# ///
"""Create sqrlbot's OWN Apple Distribution signing cert directly via the ASC API
(self-generated key + CSR, bypassing Xcode's machine-tied automatic path), then
import key+cert into the dedicated webvm-sign keychain so codesign can use it
headlessly. Does NOT touch cseaman's existing certs."""
import base64, subprocess, tempfile, time, os, sys, jwt, requests
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.serialization import pkcs12, PrivateFormat
from cryptography import x509
from cryptography.x509.oid import NameOID

ASC_ENV = "/Users/cseaman/projects/webvm/ios/.asc.env"
KEYCHAIN = "webvm-sign.keychain"
KC_PW = open("/Users/sqrlbot/.webvm-sign-kc.pw").read().strip()
CERT_TYPE = "DISTRIBUTION"   # "Apple Distribution"

def load_env(p):
    e = {}
    for l in open(p):
        l = l.strip()
        if l and not l.startswith("#") and "=" in l:
            k, v = l.split("=", 1); e[k.strip()] = v.strip().strip('"').strip("'")
    return e
env = load_env(ASC_ENV)
kid, iss = env["ASC_KEY_ID"], env["ASC_ISSUER_ID"]
p8 = open(f"/Users/sqrlbot/.appstoreconnect/private_keys/AuthKey_{kid}.p8").read()
now = int(time.time())
tok = jwt.encode({"iss": iss, "iat": now, "exp": now+600, "aud": "appstoreconnect-v1"},
                 p8, algorithm="ES256", headers={"kid": kid, "typ": "JWT"})
H = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}

# 1. keypair + CSR
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
csr = (x509.CertificateSigningRequestBuilder()
       .subject_name(x509.Name([
           x509.NameAttribute(NameOID.COMMON_NAME, "WebVM sqrlbot Distribution"),
           x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
       ]))
       .sign(key, hashes.SHA256()))
csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()

# 2. create the cert via ASC API
print(f"POST /v1/certificates type={CERT_TYPE} ...", flush=True)
r = requests.post("https://api.appstoreconnect.apple.com/v1/certificates", headers=H,
                  json={"data": {"type": "certificates",
                                 "attributes": {"certificateType": CERT_TYPE, "csrContent": csr_pem}}},
                  timeout=30)
if r.status_code not in (200, 201):
    print(f"FAILED HTTP {r.status_code}: {r.text[:600]}", file=sys.stderr); sys.exit(1)
attrs = r.json()["data"]["attributes"]
cert_id = r.json()["data"]["id"]
cert_der = base64.b64decode(attrs["certificateContent"])
cert = x509.load_der_x509_certificate(cert_der)
print(f"  created cert id={cert_id} name={attrs.get('displayName')} expires={attrs.get('expirationDate','')[:10]}", flush=True)

def sec(*args, **kw):
    return subprocess.run(["security", *args], capture_output=True, text=True, **kw)
def revoke(cid):
    now2 = int(time.time())
    t2 = jwt.encode({"iss": iss, "iat": now2, "exp": now2+600, "aud": "appstoreconnect-v1"},
                    p8, algorithm="ES256", headers={"kid": kid, "typ": "JWT"})
    return requests.delete(f"https://api.appstoreconnect.apple.com/v1/certificates/{cid}",
                           headers={"Authorization": f"Bearer {t2}"}, timeout=30).status_code
def fail(msg):
    print("FAILED:", msg, "— revoking just-created cert", cert_id, file=sys.stderr)
    print("revoke status:", revoke(cert_id), file=sys.stderr)
    sys.exit(1)

# 3. bundle key+cert into a LEGACY .p12 (3DES/SHA1) that macOS `security import` accepts
enc = (PrivateFormat.PKCS12.encryption_builder()
       .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
       .hmac_hash(hashes.SHA1())
       .build(b"import"))
p12 = pkcs12.serialize_key_and_certificates(b"webvm-sqrlbot-dist", key, cert, None, enc)
with tempfile.NamedTemporaryFile(suffix=".p12", delete=False) as f:
    f.write(p12); p12_path = f.name

sec("unlock-keychain", "-p", KC_PW, KEYCHAIN)
imp = sec("import", p12_path, "-k", KEYCHAIN, "-P", "import",
          "-T", "/usr/bin/codesign", "-T", "/usr/bin/xcodebuild", "-T", "/usr/bin/productbuild")
os.unlink(p12_path)
print("import:", imp.stdout.strip() or imp.stderr.strip(), flush=True)
if imp.returncode != 0 and "already exists" not in (imp.stderr or ""):
    fail("keychain import: " + imp.stderr.strip())

# 4. authorize the tools to use the key non-interactively (avoids errSecInternalComponent)
part = sec("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", KC_PW, KEYCHAIN)
print("partition-list:", "ok" if part.returncode == 0 else part.stderr.strip(), flush=True)

# 5. confirm a valid signing identity now exists
ident = sec("find-identity", "-v", "-p", "codesigning", KEYCHAIN)
print("=== valid codesigning identities in", KEYCHAIN, "===")
print(ident.stdout.strip())
if ident.stdout.strip().startswith("0"):
    # Almost always the WWDR intermediate is missing (leaf can't chain) — NOT a
    # reason to revoke; keep the cert, install WWDR, and re-check.
    print("WARNING: 0 valid — likely missing WWDR intermediate; keeping cert for chain fix", file=sys.stderr)
print("CERT_ID=" + cert_id)
