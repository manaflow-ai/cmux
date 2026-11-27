#!/usr/bin/env python3
"""Raw R2 PUT/GET latency with SigV4 over one keep-alive HTTPS connection. Env: ACCESS_KEY, SECRET_KEY, SESSION_TOKEN, R2_ACCOUNT_ID, optional R2_BUCKET and R2_PREFIX."""
import hashlib, hmac, http.client, os, time, datetime, statistics, json

AK, SK, TOK = os.environ["ACCESS_KEY"], os.environ["SECRET_KEY"], os.environ["SESSION_TOKEN"]
HOST = f"{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com"; BUCKET = os.environ.get("R2_BUCKET", "cmuxnp-dev-teamfs-spike"); PFX = os.environ.get("R2_PREFIX", "teamfs-t1/") + "r2put/"

def sign(method, key, body):
    now = datetime.datetime.now(datetime.timezone.utc); amz = now.strftime("%Y%m%dT%H%M%SZ"); day = now.strftime("%Y%m%d")
    ph = hashlib.sha256(body).hexdigest(); path = f"/{BUCKET}/{key}"
    hdrs = {"host": HOST, "x-amz-content-sha256": ph, "x-amz-date": amz, "x-amz-security-token": TOK}
    sh = ";".join(sorted(hdrs)); ch = "".join(f"{k}:{hdrs[k]}\n" for k in sorted(hdrs))
    creq = f"{method}\n{path}\n\n{ch}\n{sh}\n{ph}"; scope = f"{day}/auto/s3/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{amz}\n{scope}\n{hashlib.sha256(creq.encode()).hexdigest()}"
    k = ("AWS4" + SK).encode()
    for m in (day, "auto", "s3", "aws4_request"): k = hmac.new(k, m.encode(), hashlib.sha256).digest()
    hdrs["authorization"] = f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, SignedHeaders={sh}, Signature={hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()}"
    return path, hdrs

c = http.client.HTTPSConnection(HOST)
def req(method, key, body=b""):
    path, h = sign(method, key, body); t = time.perf_counter(); c.request(method, path, body=body, headers=h); r = c.getresponse(); r.read()
    assert r.status in (200, 204), r.status
    return (time.perf_counter() - t) * 1000

def st(xs): xs = sorted(xs); return {"n": len(xs), "p50": round(statistics.median(xs), 1), "p95": round(xs[int(0.95 * len(xs)) - 1], 1), "max": round(xs[-1], 1)}
for size in (4096, 65536, 1048576):
    body = os.urandom(size); put = [req("PUT", f"{PFX}o{size}-{i}", body) for i in range(30)]; get = [req("GET", f"{PFX}o{size}-{i}") for i in range(30)]
    print(json.dumps({"size": size, "put": st(put), "get": st(get)}))
for size in (4096, 65536, 1048576):
    for i in range(30): req("DELETE", f"{PFX}o{size}-{i}")
