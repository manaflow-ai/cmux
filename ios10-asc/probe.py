#!/usr/bin/env python3
"""One-off App Store Connect probe for cmux INTERNAL (6791408425).

read: prints the submission-relevant state of the record (secrets redacted).
plan: applies the ops in plan.json (each {"method","path","body"}), then reads.
The log is public: review contact/demo values print as presence only.
"""
from __future__ import annotations

import base64, json, os, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request

APP = os.environ.get("ASC_APP_ID", "6791408425")
BASE = "https://api.appstoreconnect.apple.com"
SECRET_FIELDS = {"demoAccountPassword", "demoAccountName", "contactPhone", "contactEmail", "contactFirstName", "contactLastName"}


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        n = der[i + 1]
        out += der[i + 2:i + 2 + n].lstrip(b"\x00").rjust(32, b"\x00")
        i += 2 + n
    return out


def token() -> str:
    kid, iss, key = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_PRIVATE_KEY_PATH"]
    now = int(time.time())
    h = b64u(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}).encode())
    c = b64u(json.dumps({"iss": iss, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=f"{h}.{c}".encode(), capture_output=True, check=True).stdout
    return f"{h}.{c}.{b64u(der_to_raw(sig))}"


TOKEN = token()


def req(method: str, path: str, body=None):
    url = path if path.startswith("http") else BASE + path
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read() or b"{}")
        except ValueError:
            err = {}
        errs = [{k: x.get(k) for k in ("code", "title", "detail", "source")} for x in err.get("errors", [])]
        return e.code, {"errors": errs}


def get(path: str):
    st, body = req("GET", path)
    if st >= 300:
        print(f"  ! GET {path.split('?')[0]} -> {st} {json.dumps(body)[:600]}")
        return None
    return body


def get_all(path: str) -> list:
    out, url = [], path
    for _ in range(20):
        body = get(url)
        if body is None:
            return out
        out.extend(body.get("data") or [])
        url = (body.get("links") or {}).get("next")
        if not url:
            break
    return out


def red(attrs: dict) -> dict:
    return {k: (("<set>" if v else "<empty>") if k in SECRET_FIELDS else v) for k, v in (attrs or {}).items()}


def short(v, n=160):
    if isinstance(v, str) and len(v) > n:
        return f"{v[:n]}... ({len(v)} chars)"
    return v


def section(t):
    print(f"\n===== {t}")


def read():
    section("app")
    app = get(f"/v1/apps/{APP}")
    if app:
        print(json.dumps(app["data"]["attributes"], indent=1))
    section("appInfos + localizations")
    for info in get_all(f"/v1/apps/{APP}/appInfos"):
        a = info["attributes"]
        print(f"appInfo {info['id']}: state={a.get('state')} appStoreState={a.get('appStoreState')} ageRating={a.get('appStoreAgeRating')}")
        for rel in ("primaryCategory", "secondaryCategory"):
            b = get(f"/v1/appInfos/{info['id']}/{rel}")
            print(f"  {rel}: {(b or {}).get('data') and b['data']['id']}")
        for loc in get_all(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=50"):
            la = loc["attributes"]
            print(f"  [{la.get('locale')}] name={la.get('name')!r} subtitle={la.get('subtitle')!r} privacyPolicyUrl={la.get('privacyPolicyUrl')!r} privacyChoicesUrl={la.get('privacyChoicesUrl')!r}")
    section("appStoreVersions")
    versions = get_all(f"/v1/apps/{APP}/appStoreVersions?limit=50")
    for v in versions:
        a = v["attributes"]
        print(f"version {v['id']}: {json.dumps(a)}")
        b = get(f"/v1/appStoreVersions/{v['id']}/build")
        if b and b.get("data"):
            ba = b["data"]["attributes"]
            print(f"  build: {ba.get('version')} uploaded={ba.get('uploadedDate')} state={ba.get('processingState')} nonExemptEnc={ba.get('usesNonExemptEncryption')}")
        else:
            print("  build: none attached")
        rd = get(f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail")
        if rd and rd.get("data"):
            ra = rd["data"]["attributes"]
            notes = ra.pop("notes", None)
            print(f"  reviewDetail {rd['data']['id']}: {json.dumps(red(ra))}")
            print(f"  reviewNotes ({len(notes or '')} chars): {short(notes, 300)!r}")
        else:
            print("  reviewDetail: none")
        for rel in ("ageRatingDeclaration", "appStoreVersionPhasedRelease", "routingAppCoverage"):
            pass
        for loc in get_all(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations?limit=50"):
            la = loc["attributes"]
            print(f"  [{la.get('locale')}] loc {loc['id']} desc={short(la.get('description'), 60)!r} keywords={la.get('keywords')!r} promo={short(la.get('promotionalText'), 60)!r} support={la.get('supportUrl')!r} marketing={la.get('marketingUrl')!r} whatsNew={short(la.get('whatsNew'), 40)!r}")
            sets = get_all(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets?limit=50")
            summary = []
            for s in sets:
                shots = get_all(f"/v1/appScreenshotSets/{s['id']}/appScreenshots?limit=50")
                states = sorted({(x['attributes'].get('assetDeliveryState') or {}).get('state', '?') for x in shots})
                summary.append(f"{s['attributes'].get('screenshotDisplayType')}={len(shots)}{states}")
            print(f"     screenshots: {summary or 'none'}")
    section("preReleaseVersions (TestFlight trains)")
    for p in get_all(f"/v1/preReleaseVersions?filter[app]={APP}&limit=50"):
        print(f"  {p['attributes']}")
    section("builds (latest 15)")
    b = get(f"/v1/builds?filter[app]={APP}&sort=-uploadedDate&limit=15&include=preReleaseVersion")
    if b:
        pre = {x["id"]: x["attributes"].get("version") for x in b.get("included", []) if x["type"] == "preReleaseVersions"}
        for x in b["data"]:
            a = x["attributes"]
            pid = ((x.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}
            print(f"  {pre.get(pid.get('id'))} ({a.get('version')}) {a.get('uploadedDate')} {a.get('processingState')} expired={a.get('expired')} nonExemptEnc={a.get('usesNonExemptEncryption')} minOs={a.get('minOsVersion')} id={x['id']}")
    section("in-app purchases v2")
    for x in get_all(f"/v1/apps/{APP}/inAppPurchasesV2?limit=50"):
        print(f"  {x['id']}: {x['attributes']}")
    section("subscription groups + subscriptions")
    for g in get_all(f"/v1/apps/{APP}/subscriptionGroups?limit=50"):
        print(f"  group {g['id']}: {g['attributes']}")
        for s in get_all(f"/v1/subscriptionGroups/{g['id']}/subscriptions?limit=50"):
            print(f"    sub {s['id']}: {s['attributes']}")
            ls = get_all(f"/v1/subscriptions/{s['id']}/subscriptionLocalizations?limit=50")
            print(f"      localizations: {[(l['attributes'].get('locale'), l['attributes'].get('name'), l['attributes'].get('state')) for l in ls]}")
            rs = get(f"/v1/subscriptions/{s['id']}/appStoreReviewScreenshot")
            print(f"      reviewScreenshot: {bool(rs and rs.get('data'))}")
            pr = get(f"/v1/subscriptions/{s['id']}/prices?limit=3")
            print(f"      prices (first page count): {len((pr or {}).get('data') or [])}")
            av = get(f"/v1/subscriptions/{s['id']}/subscriptionAvailability")
            print(f"      availability: {(av or {}).get('data') and av['data']['attributes']}")
        gl = get_all(f"/v1/subscriptionGroups/{g['id']}/subscriptionGroupLocalizations?limit=50")
        print(f"    group localizations: {[(l['attributes'].get('locale'), l['attributes'].get('name'), l['attributes'].get('state')) for l in gl]}")
    section("pricing / availability")
    ps = get(f"/v1/apps/{APP}/appPriceSchedule?include=baseTerritory,manualPrices")
    if ps:
        print(f"  priceSchedule: base={(ps['data'].get('relationships') or {}).get('baseTerritory', {}).get('data')} included={[ (i['type'], i.get('attributes')) for i in ps.get('included', [])][:5]}")
    av = get(f"/v1/apps/{APP}/appAvailabilityV2")
    if av and av.get("data"):
        print(f"  availabilityV2 {av['data']['id']}: {av['data']['attributes']}")
        ta = get(f"/v2/appAvailabilities/{av['data']['id']}/territoryAvailabilities?limit=200")
        if ta:
            avail = [x for x in ta.get("data", []) if x["attributes"].get("available")]
            print(f"  territories: {len(avail)} available of {len(ta.get('data', []))} (first page); total meta={ta.get('meta')}")
    else:
        print("  availabilityV2: none")
    section("review submissions")
    for x in get_all(f"/v1/apps/{APP}/reviewSubmissions?filter[platform]=IOS&limit=20"):
        print(f"  {x['id']}: {x['attributes']}")
    section("encryption declarations")
    for x in get_all(f"/v1/apps/{APP}/appEncryptionDeclarations?limit=20"):
        print(f"  {x['id']}: {x['attributes']}")
    section("EULA")
    e = get(f"/v1/apps/{APP}/endUserLicenseAgreement")
    print(f"  custom EULA: {bool(e and e.get('data'))}")


def plan():
    ops = json.load(open(os.path.join(os.path.dirname(__file__), "plan.json")))
    for op in ops:
        st, body = req(op["method"], op["path"], op.get("body"))
        shown = body if st >= 300 else {"id": (body.get("data") or {}).get("id"), "attributes": red((body.get("data") or {}).get("attributes") or {})}
        print(f"PLAN {op['method']} {op['path']} -> {st} {short(json.dumps(shown), 800)}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "read"
    if mode == "plan":
        plan()
    read()
