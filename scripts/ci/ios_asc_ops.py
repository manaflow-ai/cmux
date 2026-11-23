#!/usr/bin/env python3
"""App Store Connect operations agents can run without a person: ios-asc-ops.yml runs this with the ASC API key.

The key (ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64) lives only in the `release` environment, which
deploys from main, `rc/**` and `v*`. ios-asc-ops.yml runs from main, decodes the key to a 0600 file for one job and
calls this script with one fixed operation. Nothing here prints the key; review-detail reads drop the demo account's
password before printing.

  ios_asc_ops.py OP [--app ID] [--version STRING] [--attributes JSON] [--path PATH] [--locale LOCALE]

Operations (reads first; every write prints the object it wrote, read back after the write):
  app-info            the app, its appInfos (state, age rating) and its App Store versions
  versions            the app's App Store versions (id, versionString, appStoreState, platform)
  age-rating          every appInfo's ageRatingDeclaration attributes
  review-detail       the App Store review detail of a version (--version, else the editable one)
  submissions         the app's review submissions and their states
  get                 a read of one App Store Connect path (--path /v1/..., GET only)
  age-rating-patch    PATCH the editable appInfo's ageRatingDeclaration with --attributes JSON, then read it back
  review-detail-sync  set the review detail's attributes (notes, contact, demo account) from --attributes JSON on
                      --version (else the editable one); creates the detail when the version has none
  version-localization-patch
                      PATCH one App Store version localization (--locale, default en-US) of --version (else the
                      editable one) with --attributes JSON; only whatsNew and promotionalText, then read it back
  subscriptions       the app's subscription groups and products: state, level, US price, territories priced,
                      localizations, review screenshot (the price book's read-back)
  price-book-sync     make the app's "cmux Plans" products match PRICE_BOOK (RFD 0037a, web/services/billing/apple/
                      config.ts): create missing groups and products, set levels, en-US and ja names and descriptions,
                      availability in every territory, the US base price and Apple's equalized price in every other
                      territory; idempotent (only what differs is written), then the `subscriptions` read-back
  review-screenshot-sync  upload ios/AppStoreReview/subscriptions/paywall.png as the App Review screenshot of each
                      price-book product that has none

Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH. Stock python3 and openssl; no packages.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
APPS = {
    "6791408425": "cmux INTERNAL (dev.cmux.app.internal)",
    "6783338052": "cmux (com.cmux.app)",
    "6757092429": "cmux CLASSIC beta (dev.cmux.app.beta)",
}
DEFAULT_APP = "6791408425"
EDITABLE_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                   "INVALID_BINARY", "READY_FOR_REVIEW")
EDITABLE_INFO_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "READY_FOR_REVIEW",
                        "WAITING_FOR_REVIEW")
REVIEW_DETAIL_KEYS = ("contactFirstName", "contactLastName", "contactPhone", "contactEmail", "demoAccountName",
                      "demoAccountPassword", "demoAccountRequired", "notes")
REDACT = ("demoAccountPassword",)
PATH_RE = re.compile(r"/v[12]/[A-Za-z0-9_/.\-]+(\?[A-Za-z0-9_=&%\[\],.\-]*)?")
READS = ("app-info", "versions", "age-rating", "review-detail", "submissions", "get", "subscriptions")
VERSION_LOCALIZATION_KEYS = ("whatsNew", "promotionalText")
VERSION_LOCALIZATION_FIELDS = "locale,whatsNew,promotionalText,description,keywords"
LOCALE_RE = re.compile(r"[A-Za-z]{2,3}(-[A-Za-z0-9]{2,4})?")
WRITES = ("age-rating-patch", "review-detail-sync", "version-localization-patch", "price-book-sync",
          "review-screenshot-sync")


# ---- the JWT (same shape as scripts/ci/ios_internal_notes.py on feat-cmux-next) ----

def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _der_to_raw(der: bytes) -> bytes:
    """ECDSA DER signature to the JWS r||s form (32 bytes each)."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER signature")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER integer")
        n = der[i + 1]
        value = der[i + 2:i + 2 + n].lstrip(b"\x00")
        if len(value) > 32:
            raise ValueError("integer too long for P-256")
        out += value.rjust(32, b"\x00")
        i += 2 + n
    return out


def asc_token(key_id: str, issuer: str, key_path: str, now: int | None = None) -> str:
    now = int(now if now is not None else time.time())
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    claims = _b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                                separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                         capture_output=True, check=True).stdout
    return f"{header}.{claims}.{_b64url(_der_to_raw(der))}"


# ---- HTTP ----

class Client:
    """One App Store Connect session. `token` is a JWT or a function minting one; a minted token is renewed every
    10 minutes (it lives 15), so a price-book sync of several hundred calls outlives none. HTTP 429 waits and retries."""

    def __init__(self, token, opener=urllib.request.urlopen, sleep=time.sleep):
        self.mint = token if callable(token) else None
        self.token = token() if callable(token) else token
        self.minted = time.time()
        self.opener = opener
        self.sleep = sleep

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        if self.mint and time.time() - self.minted > 600:
            self.token, self.minted = self.mint(), time.time()
        data = json.dumps(body).encode() if body is not None else None
        url = path if path.startswith(API + "/") else API + path
        for attempt in range(6):
            req = urllib.request.Request(url, data=data, method=method, headers={
                "Authorization": f"Bearer {self.token}", "Accept": "application/json",
                **({"Content-Type": "application/json"} if data is not None else {})})
            try:
                with self.opener(req, timeout=60) as resp:
                    raw = resp.read()
                return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as err:
                detail = err.read().decode(errors="replace")[:2000]
                if err.code == 429 and attempt < 5:
                    self.sleep(10 * (attempt + 1))
                    continue
                raise SystemExit(f"{method} {path}: HTTP {err.code}: {detail}") from None
        raise SystemExit(f"{method} {path}: rate limited")

    def get(self, path: str) -> dict:
        return self.call("GET", path)


def redact(value):
    if isinstance(value, dict):
        return {k: ("<redacted>" if k in REDACT and v else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


# ---- reads ----

def versions(client: Client, app: str) -> list[dict]:
    q = urllib.parse.urlencode({"limit": "50", "fields[appStoreVersions]": "versionString,appStoreState,platform,"
                                                                          "createdDate,releaseType"})
    return [{"id": v["id"], **v.get("attributes", {})}
            for v in client.get(f"/v1/apps/{app}/appStoreVersions?{q}").get("data", [])]


def app_infos(client: Client, app: str) -> list[dict]:
    return [{"id": i["id"], **i.get("attributes", {})} for i in client.get(f"/v1/apps/{app}/appInfos").get("data", [])]


def editable_version(client: Client, app: str, version: str | None) -> dict:
    found = versions(client, app)
    if version:
        match = [v for v in found if v.get("versionString") == version]
    else:
        match = [v for v in found if v.get("appStoreState") in EDITABLE_STATES]
    if not match:
        raise SystemExit(f"no App Store version {'named ' + version if version else 'in an editable state'} on app "
                         f"{app}; versions: {[(v.get('versionString'), v.get('appStoreState')) for v in found]}")
    return match[0]


def editable_info(client: Client, app: str) -> dict:
    infos = app_infos(client, app)
    for info in infos:
        if (info.get("appStoreState") or info.get("state")) in EDITABLE_INFO_STATES:
            return info
    if len(infos) == 1:
        return infos[0]
    raise SystemExit(f"no editable appInfo on app {app}: {[(i['id'], i.get('appStoreState') or i.get('state')) for i in infos]}")


def age_ratings(client: Client, app: str) -> list[dict]:
    out = []
    for info in app_infos(client, app):
        decl = client.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data") or {}
        out.append({"appInfo": info["id"], "appInfoState": info.get("appStoreState") or info.get("state"),
                    "declaration": decl.get("id"), "attributes": decl.get("attributes", {})})
    return out


def review_detail(client: Client, version_id: str) -> dict | None:
    try:
        data = client.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail").get("data")
    except SystemExit as err:
        if "HTTP 404" in str(err):
            return None
        raise
    return {"id": data["id"], **data.get("attributes", {})} if data else None


def version_localizations(client: Client, version_id: str) -> list[dict]:
    q = urllib.parse.urlencode({"limit": "50", "fields[appStoreVersionLocalizations]": VERSION_LOCALIZATION_FIELDS})
    return [{"id": loc["id"], **loc.get("attributes", {})} for loc in
            client.get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?{q}").get("data", [])]


def version_localization(client: Client, loc_id: str) -> dict:
    q = urllib.parse.urlencode({"fields[appStoreVersionLocalizations]": VERSION_LOCALIZATION_FIELDS})
    data = client.get(f"/v1/appStoreVersionLocalizations/{loc_id}?{q}").get("data") or {}
    return {"id": data.get("id", loc_id), **data.get("attributes", {})}


# ---- subscriptions: the App Store price book (RFD 0037a) ----
#
# The App Store column of the one price book: web price / 0.7, rounded up to the next .99 App Store point, US base,
# Apple's equalization everywhere else. Product IDs and USD prices must equal web/services/billing/apple/config.ts
# (appleProductId, APPLE_USD_LIST_PRICE); tests/test_ios_asc_ops.py checks them against it. Levels: 1 is highest.

GROUP_NAME = "cmux Plans"
GROUP_LOCALIZATIONS = {"en-US": "cmux", "ja": "cmux"}
BUNDLES = {"6783338052": "com.cmux.app", "6791408425": "dev.cmux.app.internal", "6757092429": "dev.cmux.app.beta"}
NEXT_PRODUCTS = (
    {"plan": "next_max", "usd": "299.99", "level": 1,
     "localizations": {"en-US": ("cmux Max", "300,000 machine-minutes a month and 5 Chiefs"),
                       "ja": ("cmux Max", "毎月300,000マシン分とChief 5体")}},
    {"plan": "next_pro", "usd": "74.99", "level": 2,
     "localizations": {"en-US": ("cmux Pro", "75,000 machine-minutes a month and 2 Chiefs"),
                       "ja": ("cmux Pro", "毎月75,000マシン分とChief 2体")}},
    {"plan": "next_plus", "usd": "29.99", "level": 3,
     "localizations": {"en-US": ("cmux Plus", "30,000 machine-minutes a month and 1 Chief"),
                       "ja": ("cmux Plus", "毎月30,000マシン分とChief 1体")}},
)
CLASSIC_PRODUCTS = (
    {"plan": "max", "usd": "299.99", "level": 1,
     "localizations": {"en-US": ("cmux Max", "Up to 5 Cloud VMs sharing 80 vCPUs and 160 GB RAM"),
                       "ja": ("cmux Max", "クラウドVM最大5台で80 vCPU・160 GB RAMを共有")}},
    {"plan": "pro", "usd": "74.99", "level": 2,
     "localizations": {"en-US": ("cmux Pro", "Up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM"),
                       "ja": ("cmux Pro", "クラウドVM最大5台で20 vCPU・40 GB RAMを共有")}},
    {"plan": "go", "usd": "21.99", "level": 3,
     "localizations": {"en-US": ("cmux Go", "1 Cloud VM with up to 8 vCPUs and 16 GB RAM"),
                       "ja": ("cmux Go", "クラウドVM 1台、最大8 vCPU・16 GB RAM")}},
)
# The classic beta sells the classic book; the cmux-next apps sell NEXT, and com.cmux.app's unapproved classic
# products (to be taken off sale) move below NEXT in the same group, keeping their own prices and text.
PRICE_BOOK = {"6783338052": NEXT_PRODUCTS, "6791408425": NEXT_PRODUCTS, "6757092429": CLASSIC_PRODUCTS}
LEGACY_LEVELS = {"6783338052": ("max", "pro", "go")}
REVIEW_SCREENSHOT = Path(__file__).resolve().parents[2] / "ios/AppStoreReview/subscriptions/paywall.png"


def product_id(app: str, plan: str) -> str:
    return f"{BUNDLES[app]}.{plan}.monthly"


def get_all(client: Client, path: str) -> tuple[list[dict], list[dict]]:
    """Every page of a list: (data, included)."""
    data, included, nxt = [], [], path
    while nxt:
        page = client.get(nxt)
        data += page.get("data") or []
        included += page.get("included") or []
        nxt = (page.get("links") or {}).get("next")
    return data, included


def rel_id(obj: dict, name: str) -> str | None:
    return (((obj.get("relationships") or {}).get(name) or {}).get("data") or {}).get("id")


def same_price(a, b) -> bool:
    try:
        return abs(float(a) - float(b)) < 0.005
    except (TypeError, ValueError):
        return False


def find_group(client: Client, app: str) -> dict | None:
    groups, _ = get_all(client, f"/v1/apps/{app}/subscriptionGroups?limit=50")
    for g in groups:
        if (g.get("attributes") or {}).get("referenceName") == GROUP_NAME:
            return g
    return groups[0] if len(groups) == 1 else None


def group_subscriptions(client: Client, group_id: str) -> list[dict]:
    subs, _ = get_all(client, f"/v1/subscriptionGroups/{group_id}/subscriptions?limit=200")
    return subs


def current_prices(client: Client, sub_id: str) -> dict[str, dict]:
    """Territory -> the price in effect (or the newest one when none has started), with its price point."""
    today = time.strftime("%Y-%m-%d", time.gmtime())
    rows, included = get_all(client, f"/v1/subscriptions/{sub_id}/prices?limit=200&include=subscriptionPricePoint,"
                                      f"territory&fields[subscriptionPricePoints]=customerPrice,proceeds")
    points = {i["id"]: i.get("attributes", {}) for i in included if i.get("type") == "subscriptionPricePoints"}
    started: dict[str, dict] = {}
    future: dict[str, dict] = {}
    for row in rows:
        territory = rel_id(row, "territory")
        if not territory:
            continue
        point = rel_id(row, "subscriptionPricePoint")
        start = (row.get("attributes") or {}).get("startDate") or ""
        entry = {"id": row["id"], "pricePoint": point, "startDate": start or None,
                 "customerPrice": points.get(point, {}).get("customerPrice")}
        if start <= today:
            if territory not in started or (started[territory]["startDate"] or "") <= start:
                started[territory] = entry
        elif territory not in future or start < future[territory]["startDate"]:
            future[territory] = entry
    return {**future, **started}


def read_subscription(client: Client, sub: dict) -> dict:
    attrs = sub.get("attributes") or {}
    prices = current_prices(client, sub["id"])
    locs, _ = get_all(client, f"/v1/subscriptions/{sub['id']}/subscriptionLocalizations?limit=50")
    try:
        shot = client.get(f"/v1/subscriptions/{sub['id']}/appStoreReviewScreenshot").get("data")
    except SystemExit as err:
        if "HTTP 404" not in str(err):
            raise
        shot = None
    try:
        avail = client.get(f"/v1/subscriptions/{sub['id']}/subscriptionAvailability").get("data")
    except SystemExit as err:
        if "HTTP 404" not in str(err):
            raise
        avail = None
    usa = prices.get("USA") or {}
    return {"id": sub["id"], "productId": attrs.get("productId"), "name": attrs.get("name"),
            "state": attrs.get("state"), "groupLevel": attrs.get("groupLevel"),
            "subscriptionPeriod": attrs.get("subscriptionPeriod"),
            "usPrice": usa.get("customerPrice"), "usPriceStart": usa.get("startDate"),
            "territoriesPriced": len(prices),
            "availableInNewTerritories": ((avail or {}).get("attributes") or {}).get("availableInNewTerritories"),
            "localizations": {(l.get("attributes") or {}).get("locale"): {
                "name": (l.get("attributes") or {}).get("name"),
                "description": (l.get("attributes") or {}).get("description"),
                "state": (l.get("attributes") or {}).get("state")} for l in locs},
            "reviewScreenshot": ((shot or {}).get("attributes") or {}).get("assetDeliveryState") if shot else None}


def read_subscriptions(client: Client, app: str) -> dict:
    groups, _ = get_all(client, f"/v1/apps/{app}/subscriptionGroups?limit=50")
    out = []
    for g in groups:
        subs = sorted(group_subscriptions(client, g["id"]),
                      key=lambda s: ((s.get("attributes") or {}).get("groupLevel") or 99))
        out.append({"id": g["id"], "referenceName": (g.get("attributes") or {}).get("referenceName"),
                    "subscriptions": [read_subscription(client, s) for s in subs]})
    expected = [{"productId": product_id(app, p["plan"]), "usd": p["usd"], "level": p["level"]}
                for p in PRICE_BOOK.get(app, ())]
    found = {s["productId"]: s for g in out for s in g["subscriptions"]}
    check = [{**e, "found": e["productId"] in found,
              "usPrice": (found.get(e["productId"]) or {}).get("usPrice"),
              "priceMatches": same_price((found.get(e["productId"]) or {}).get("usPrice"), e["usd"]),
              "state": (found.get(e["productId"]) or {}).get("state")} for e in expected]
    return {"groups": out, "priceBook": check, "priceBookLive": all(c["found"] and c["priceMatches"] for c in check)}


def ensure_group(client: Client, app: str, log: list) -> dict:
    group = find_group(client, app)
    if group is None:
        group = client.call("POST", "/v1/subscriptionGroups", {"data": {
            "type": "subscriptionGroups", "attributes": {"referenceName": GROUP_NAME},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]
        log.append(f"created group {GROUP_NAME} {group['id']}")
    locs, _ = get_all(client, f"/v1/subscriptionGroups/{group['id']}/subscriptionGroupLocalizations?limit=50")
    have = {(l.get("attributes") or {}).get("locale") for l in locs}
    for locale, name in GROUP_LOCALIZATIONS.items():
        if locale not in have:
            client.call("POST", "/v1/subscriptionGroupLocalizations", {"data": {
                "type": "subscriptionGroupLocalizations", "attributes": {"locale": locale, "name": name},
                "relationships": {"subscriptionGroup": {"data": {"type": "subscriptionGroups", "id": group["id"]}}}}})
            log.append(f"group localization {locale}")
    return group


def ensure_subscription(client: Client, app: str, group_id: str, product: dict, subs: list[dict], log: list) -> dict:
    pid = product_id(app, product["plan"])
    for sub in subs:
        if (sub.get("attributes") or {}).get("productId") == pid:
            return sub
    name = product["localizations"]["en-US"][0] + " monthly"
    sub = client.call("POST", "/v1/subscriptions", {"data": {
        "type": "subscriptions",
        "attributes": {"name": name, "productId": pid, "subscriptionPeriod": "ONE_MONTH", "familySharable": False},
        "relationships": {"group": {"data": {"type": "subscriptionGroups", "id": group_id}}}}})["data"]
    log.append(f"created {pid} {sub['id']}")
    subs.append(sub)
    return sub


def ensure_levels(client: Client, app: str, subs: list[dict], log: list, errors: list) -> None:
    """Price-book products take levels 1..n in order; any legacy products follow in their listed order."""
    order = [product_id(app, p["plan"]) for p in PRICE_BOOK[app]]
    order += [product_id(app, plan) for plan in LEGACY_LEVELS.get(app, ())]
    by_pid = {(s.get("attributes") or {}).get("productId"): s for s in subs}
    for level, pid in enumerate(order, start=1):
        sub = by_pid.get(pid)
        if sub is None or (sub.get("attributes") or {}).get("groupLevel") == level:
            continue
        try:
            client.call("PATCH", f"/v1/subscriptions/{sub['id']}", {"data": {
                "type": "subscriptions", "id": sub["id"], "attributes": {"groupLevel": level}}})
            log.append(f"{pid} level {level}")
        except SystemExit as err:
            errors.append(f"{pid} level {level}: {str(err)[:300]}")


def ensure_localizations(client: Client, sub: dict, product: dict, log: list) -> None:
    locs, _ = get_all(client, f"/v1/subscriptions/{sub['id']}/subscriptionLocalizations?limit=50")
    by_locale = {(l.get("attributes") or {}).get("locale"): l for l in locs}
    pid = (sub.get("attributes") or {}).get("productId")
    for locale, (name, description) in product["localizations"].items():
        have = by_locale.get(locale)
        if have is None:
            client.call("POST", "/v1/subscriptionLocalizations", {"data": {
                "type": "subscriptionLocalizations",
                "attributes": {"locale": locale, "name": name, "description": description},
                "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sub["id"]}}}}})
            log.append(f"{pid} {locale} localization")
        elif ((have.get("attributes") or {}).get("name"), (have.get("attributes") or {}).get("description")) != (
                name, description):
            client.call("PATCH", f"/v1/subscriptionLocalizations/{have['id']}", {"data": {
                "type": "subscriptionLocalizations", "id": have["id"],
                "attributes": {"name": name, "description": description}}})
            log.append(f"{pid} {locale} localization updated")


def ensure_availability(client: Client, sub: dict, territories: list[str], log: list) -> None:
    try:
        avail = client.get(f"/v1/subscriptions/{sub['id']}/subscriptionAvailability").get("data")
    except SystemExit as err:
        if "HTTP 404" not in str(err):
            raise
        avail = None
    if avail:
        have, _ = get_all(client, f"/v1/subscriptionAvailabilities/{avail['id']}/availableTerritories?limit=200")
        if {t["id"] for t in have} >= set(territories):
            return
    client.call("POST", "/v1/subscriptionAvailabilities", {"data": {
        "type": "subscriptionAvailabilities", "attributes": {"availableInNewTerritories": True},
        "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sub["id"]}},
                          "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}}})
    log.append(f"{(sub.get('attributes') or {}).get('productId')} available in {len(territories)} territories")


def ensure_prices(client: Client, sub: dict, usd: str, log: list, errors: list) -> None:
    """The US price point at `usd`, then its equalization in every other territory; only differing ones are written."""
    pid = (sub.get("attributes") or {}).get("productId")
    points, _ = get_all(client, f"/v1/subscriptions/{sub['id']}/pricePoints?filter[territory]=USA&limit=200"
                                f"&fields[subscriptionPricePoints]=customerPrice,proceeds")
    base = next((p for p in points if same_price((p.get("attributes") or {}).get("customerPrice"), usd)), None)
    if base is None:
        raise SystemExit(f"{pid}: no USA price point at {usd}")
    eq, _ = get_all(client, f"/v1/subscriptionPricePoints/{base['id']}/equalizations?limit=200&include=territory"
                            f"&fields[subscriptionPricePoints]=customerPrice,territory")
    targets = {"USA": base["id"]}
    for p in eq:
        territory = rel_id(p, "territory")
        if territory:
            targets[territory] = p["id"]
    have = current_prices(client, sub["id"])
    written = 0
    for territory, point in sorted(targets.items(), key=lambda kv: kv[0] != "USA"):
        if (have.get(territory) or {}).get("pricePoint") == point:
            continue
        body = {"data": {"type": "subscriptionPrices", "attributes": {"preserveCurrentPrice": False},
                         "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sub["id"]}},
                                           "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints",
                                                                               "id": point}},
                                           "territory": {"data": {"type": "territories", "id": territory}}}}}
        try:
            client.call("POST", "/v1/subscriptionPrices", body)
            written += 1
        except SystemExit as err:
            errors.append(f"{pid} {territory}: {str(err)[:300]}")
    if written:
        log.append(f"{pid} prices: {written} of {len(targets)} territories written, US {usd}")


def price_book_sync(client: Client, app: str) -> dict:
    if app not in PRICE_BOOK:
        raise SystemExit(f"app {app} has no price book")
    log: list[str] = []
    errors: list[str] = []
    before = read_subscriptions(client, app)
    group = ensure_group(client, app, log)
    subs = group_subscriptions(client, group["id"])
    territories = [t["id"] for t in get_all(client, "/v1/territories?limit=200")[0]]
    products = [(p, ensure_subscription(client, app, group["id"], p, subs, log)) for p in PRICE_BOOK[app]]
    ensure_levels(client, app, group_subscriptions(client, group["id"]), log, errors)
    for product, sub in products:
        ensure_localizations(client, sub, product, log)
        ensure_availability(client, sub, territories, log)
        ensure_prices(client, sub, product["usd"], log, errors)
    return {"group": group["id"], "log": log, "errors": errors,
            "before": before["priceBook"], "after": read_subscriptions(client, app)}


def upload_review_screenshot(client: Client, sub: dict, image: bytes, file_name: str) -> str:
    res = client.call("POST", "/v1/subscriptionAppStoreReviewScreenshots", {"data": {
        "type": "subscriptionAppStoreReviewScreenshots", "attributes": {"fileName": file_name, "fileSize": len(image)},
        "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sub["id"]}}}}})["data"]
    for op in (res.get("attributes") or {}).get("uploadOperations") or []:
        chunk = image[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op.get("method", "PUT"),
                                     headers={h["name"]: h["value"] for h in op.get("requestHeaders") or []})
        with client.opener(req, timeout=120) as resp:
            resp.read()
    client.call("PATCH", f"/v1/subscriptionAppStoreReviewScreenshots/{res['id']}", {"data": {
        "type": "subscriptionAppStoreReviewScreenshots", "id": res["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(image).hexdigest()}}})
    return res["id"]


def review_screenshot_sync(client: Client, app: str, image_path: Path = REVIEW_SCREENSHOT) -> dict:
    if app not in PRICE_BOOK:
        raise SystemExit(f"app {app} has no price book")
    if not image_path.is_file():
        raise SystemExit(f"no review screenshot at {image_path.name}: commit the paywall screenshot to "
                         "ios/AppStoreReview/subscriptions/paywall.png first")
    image = image_path.read_bytes()
    group = find_group(client, app)
    if group is None:
        raise SystemExit(f"app {app} has no {GROUP_NAME} group; run price-book-sync first")
    wanted = {product_id(app, p["plan"]) for p in PRICE_BOOK[app]}
    log = []
    for sub in group_subscriptions(client, group["id"]):
        pid = (sub.get("attributes") or {}).get("productId")
        if pid not in wanted:
            continue
        try:
            shot = client.get(f"/v1/subscriptions/{sub['id']}/appStoreReviewScreenshot").get("data")
        except SystemExit as err:
            if "HTTP 404" not in str(err):
                raise
            shot = None
        if shot:
            continue
        log.append(f"{pid} screenshot {upload_review_screenshot(client, sub, image, image_path.name)}")
    return {"log": log, "after": read_subscriptions(client, app)}


def run(op: str, args, client: Client) -> dict:
    app = args.app
    if op == "app-info":
        app_json = client.get(f"/v1/apps/{app}?fields[apps]=name,bundleId,sku,primaryLocale,contentRightsDeclaration")
        return {"app": {"id": app, **app_json.get("data", {}).get("attributes", {})},
                "appInfos": app_infos(client, app), "versions": versions(client, app),
                "ageRating": age_ratings(client, app)}
    if op == "versions":
        return {"versions": versions(client, app)}
    if op == "age-rating":
        return {"ageRating": age_ratings(client, app)}
    if op == "review-detail":
        version = editable_version(client, app, args.version)
        return {"version": version, "reviewDetail": review_detail(client, version["id"])}
    if op == "submissions":
        q = urllib.parse.urlencode({"filter[app]": app, "limit": "20",
                                    "fields[reviewSubmissions]": "state,submittedDate,platform"})
        return {"submissions": [{"id": s["id"], **s.get("attributes", {})}
                                for s in client.get(f"/v1/reviewSubmissions?{q}").get("data", [])]}
    if op == "subscriptions":
        return read_subscriptions(client, app)
    if op == "price-book-sync":
        return price_book_sync(client, app)
    if op == "review-screenshot-sync":
        return review_screenshot_sync(client, app)
    if op == "get":
        if not args.path or not PATH_RE.fullmatch(args.path):
            raise SystemExit(f"--path must be an App Store Connect API path like /v1/apps/{app}/appInfos")
        return client.get(args.path)
    attributes = parse_attributes(args.attributes)
    if op == "age-rating-patch":
        info = editable_info(client, app)
        decl = client.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data") or {}
        if not decl.get("id"):
            raise SystemExit(f"appInfo {info['id']} has no ageRatingDeclaration")
        client.call("PATCH", f"/v1/ageRatingDeclarations/{decl['id']}",
                    {"data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": attributes}})
        after = client.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data") or {}
        return {"appInfo": info["id"], "declaration": decl["id"], "before": decl.get("attributes", {}),
                "after": after.get("attributes", {})}
    if op == "review-detail-sync":
        unknown = sorted(set(attributes) - set(REVIEW_DETAIL_KEYS))
        if unknown:
            raise SystemExit(f"unknown review detail attributes {unknown}; allowed: {list(REVIEW_DETAIL_KEYS)}")
        version = editable_version(client, app, args.version)
        before = review_detail(client, version["id"])
        if before:
            client.call("PATCH", f"/v1/appStoreReviewDetails/{before['id']}",
                        {"data": {"type": "appStoreReviewDetails", "id": before["id"], "attributes": attributes}})
        else:
            client.call("POST", "/v1/appStoreReviewDetails", {"data": {
                "type": "appStoreReviewDetails", "attributes": attributes,
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
        return {"version": version, "before": before, "after": review_detail(client, version["id"])}
    if op == "version-localization-patch":
        unknown = sorted(set(attributes) - set(VERSION_LOCALIZATION_KEYS))
        if unknown:
            raise SystemExit(f"unknown version localization attributes {unknown}; allowed: "
                             f"{list(VERSION_LOCALIZATION_KEYS)}")
        if any(not isinstance(v, str) or len(v) > 4000 for v in attributes.values()):
            raise SystemExit("version localization attributes must be strings of at most 4000 characters")
        locale = args.locale or "en-US"
        if not LOCALE_RE.fullmatch(locale):
            raise SystemExit(f"--locale must be a locale like en-US, not {locale!r}")
        version = editable_version(client, app, args.version)
        if version.get("appStoreState") not in EDITABLE_STATES:
            raise SystemExit(f"version {version.get('versionString')} is {version.get('appStoreState')}, not editable")
        found = [loc for loc in version_localizations(client, version["id"]) if loc.get("locale") == locale]
        if not found:
            raise SystemExit(f"version {version.get('versionString')} has no {locale} localization")
        before = found[0]
        client.call("PATCH", f"/v1/appStoreVersionLocalizations/{before['id']}", {"data": {
            "type": "appStoreVersionLocalizations", "id": before["id"], "attributes": attributes}})
        after = version_localization(client, before["id"])
        mismatched = sorted(k for k, v in attributes.items() if after.get(k) != v)
        if mismatched:
            raise SystemExit(f"read back {mismatched} on {before['id']} differs from what was written: {after}")
        return {"version": version, "locale": locale, "before": before, "after": after}
    raise SystemExit(f"unknown op {op}")


def parse_attributes(text: str | None) -> dict:
    try:
        value = json.loads(text or "")
    except json.JSONDecodeError as err:
        raise SystemExit(f"--attributes must be a JSON object: {err}") from None
    if not isinstance(value, dict) or not value:
        raise SystemExit("--attributes must be a non-empty JSON object")
    return value


def main(argv: list[str] | None = None, client: Client | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("op", choices=READS + WRITES)
    parser.add_argument("--app", default=DEFAULT_APP)
    parser.add_argument("--version", default="")
    parser.add_argument("--attributes", default="")
    parser.add_argument("--path", default="")
    parser.add_argument("--locale", default="")
    args = parser.parse_args(argv)
    if args.app not in APPS:
        parser.error(f"--app must be one of {sorted(APPS)} ({', '.join(APPS.values())})")
    if client is None:
        key_id, issuer, key_path = (os.environ.get(k, "") for k in ("ASC_KEY_ID", "ASC_ISSUER_ID",
                                                                     "ASC_PRIVATE_KEY_PATH"))
        if not (key_id and issuer and key_path and Path(key_path).is_file()):
            print("ios_asc_ops: ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH are required", file=sys.stderr)
            return 2
        client = Client(lambda: asc_token(key_id, issuer, key_path))
    result = redact(run(args.op, args, client))
    failed = bool(result.get("errors")) or (args.op == "price-book-sync" and not result["after"]["priceBookLive"])
    text = json.dumps({"op": args.op, "app": args.app, "appName": APPS[args.app], "result": result}, indent=2,
                      sort_keys=True)
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"### ios-asc-ops `{args.op}` on {APPS[args.app]}\n\n```json\n{text[:60000]}\n```\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
