#!/usr/bin/env python3
"""Fill empty, reversible App Store fields of cmux INTERNAL (6791408425).

Only fills what is empty. Never renames the app, never touches age rating or
App Privacy, never submits. Values come from the repo metadata
(feat-cmux-next cmux-next-ios/AppStoreReview/metadata) or mirror the public
record 6783338052 (contact/demo account are copied inside the job and never
printed). Also saves the public record's en-US screenshots as an artifact.
"""
from __future__ import annotations

import json, os, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe  # noqa: E402  (token at import)

APP = "6791408425"
REF = "6783338052"
VERSION = "1.2.0"
META = os.environ.get("META_DIR", "next/cmux-next-ios/AppStoreReview/metadata")
req, get, get_all = probe.req, probe.get, probe.get_all


def do(method, path, body):
    st, out = req(method, path, body)
    ok = st < 300
    print(f"{'OK ' if ok else 'ERR'} {method} {path} -> {st}" + ("" if ok else f" {json.dumps(out)[:700]}"))
    return out if ok else None


def first_version(app):
    vs = [v for v in get_all(f"/v1/apps/{app}/appStoreVersions?limit=50") if v["attributes"]["platform"] == "IOS"]
    return vs[0] if vs else None


def main():
    ver_meta = json.load(open(f"{META}/version/1.0.0/en-US.json"))
    info_meta = json.load(open(f"{META}/app-info/en-US.json"))

    # A. version string + copyright
    v = first_version(APP)
    ref_v = first_version(REF)
    va = v["attributes"]
    patch = {}
    if va["versionString"] != VERSION and va["appStoreState"] == "PREPARE_FOR_SUBMISSION":
        patch["versionString"] = VERSION
    if not va.get("copyright") and ref_v["attributes"].get("copyright"):
        patch["copyright"] = ref_v["attributes"]["copyright"]
    if patch:
        print(f"version {v['id']}: {va['versionString']} -> {patch}")
        do("PATCH", f"/v1/appStoreVersions/{v['id']}", {"data": {"type": "appStoreVersions", "id": v["id"], "attributes": patch}})

    # B. en-US version localization: fill empties from the repo
    for loc in get_all(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations?limit=50"):
        if loc["attributes"]["locale"] != "en-US":
            continue
        attrs = {k: ver_meta[k] for k in ("description", "keywords", "promotionalText", "supportUrl", "marketingUrl")
                 if ver_meta.get(k) and not loc["attributes"].get(k)}
        if attrs:
            print(f"version en-US fill: {sorted(attrs)}")
            do("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}})

    # C/D. app info: subtitle + privacy URL (never name), categories mirrored from the public record
    info = get_all(f"/v1/apps/{APP}/appInfos")[0]
    ref_info = get_all(f"/v1/apps/{REF}/appInfos")[0]
    for loc in get_all(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=50"):
        if loc["attributes"]["locale"] != "en-US":
            continue
        attrs = {k: info_meta[k] for k in ("subtitle", "privacyPolicyUrl") if info_meta.get(k) and not loc["attributes"].get(k)}
        if attrs:
            print(f"appInfo en-US fill: {attrs}")
            do("PATCH", f"/v1/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": attrs}})
    rels = {}
    for rel in ("primaryCategory", "secondaryCategory"):
        mine = (get(f"/v1/appInfos/{info['id']}/{rel}") or {}).get("data")
        theirs = (get(f"/v1/appInfos/{ref_info['id']}/{rel}") or {}).get("data")
        if not mine and theirs:
            rels[rel] = {"data": {"type": "appCategories", "id": theirs["id"]}}
    if rels:
        print(f"categories: { {k: r['data']['id'] for k, r in rels.items()} }")
        do("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": rels}})

    # E. content rights
    app = get(f"/v1/apps/{APP}")["data"]["attributes"]
    ref_app = get(f"/v1/apps/{REF}")["data"]["attributes"]
    if not app.get("contentRightsDeclaration") and ref_app.get("contentRightsDeclaration"):
        print(f"contentRightsDeclaration -> {ref_app['contentRightsDeclaration']}")
        do("PATCH", f"/v1/apps/{APP}", {"data": {"type": "apps", "id": APP, "attributes": {"contentRightsDeclaration": ref_app["contentRightsDeclaration"]}}})

    # F. App Review information: contact + demo account mirrored (values never printed)
    keys = ("contactFirstName", "contactLastName", "contactPhone", "contactEmail", "demoAccountName", "demoAccountPassword", "demoAccountRequired")
    ref_rd = (get(f"/v1/appStoreVersions/{ref_v['id']}/appStoreReviewDetail") or {}).get("data")
    rd = (get(f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail") or {}).get("data")
    if ref_rd:
        src = {k: ref_rd["attributes"].get(k) for k in keys if ref_rd["attributes"].get(k) not in (None, "")}
        if not rd:
            print(f"review detail: create with {sorted(src)}")
            do("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": src,
               "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
        else:
            fill = {k: val for k, val in src.items() if rd["attributes"].get(k) in (None, "")}
            if fill:
                print(f"review detail: fill {sorted(fill)}")
                do("PATCH", f"/v1/appStoreReviewDetails/{rd['id']}", {"data": {"type": "appStoreReviewDetails", "id": rd["id"], "attributes": fill}})

    # G. availability mirrored from the public record
    if not (get(f"/v1/apps/{APP}/appAvailabilityV2") or {}).get("data"):
        ta = get_all(f"/v2/appAvailabilities/{REF}/territoryAvailabilities?limit=200&include=territory")
        # territory ids come from the relationship
        terr = []
        for x in ta:
            if x["attributes"].get("available"):
                t = ((x.get("relationships") or {}).get("territory") or {}).get("data")
                if not t:
                    t = (get(f"/v1/territoryAvailabilities/{x['id']}/territory") or {}).get("data")
                if t:
                    terr.append(t["id"])
        missing = [((x.get("relationships") or {}).get("territory") or {}).get("data", {}).get("id") for x in ta if not x["attributes"].get("available")]
        print(f"availability: {len(terr)} territories available (public record excludes {missing})")
        if terr:
            linkage, included = [], []
            for tid in sorted(terr):
                lid = f"${{local-{tid.lower()}}}"
                linkage.append({"type": "territoryAvailabilities", "id": lid})
                included.append({"type": "territoryAvailabilities", "id": lid, "attributes": {"available": True, "preOrderEnabled": False},
                                 "relationships": {"territory": {"data": {"type": "territories", "id": tid}}}})
            do("POST", "/v2/appAvailabilities", {"data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
               "relationships": {"app": {"data": {"type": "apps", "id": APP}}, "territoryAvailabilities": {"data": linkage}}}, "included": included})

    # H. price schedule mirrored (only a free base price)
    st, _ = req("GET", f"/v1/apps/{APP}/appPriceSchedule")
    if st == 404:
        sched = get(f"/v1/apps/{REF}/appPriceSchedule")
        mp = get(f"/v1/appPriceSchedules/{sched['data']['id']}/manualPrices?include=appPricePoint,territory&limit=50") if sched else None
        prices = sorted({i["attributes"].get("customerPrice") for i in (mp or {}).get("included", []) if i["type"] == "appPricePoints"})
        print(f"public record manual base prices: {prices}")
        if prices and all(float(p) == 0 for p in prices):
            pts = get_all(f"/v1/apps/{APP}/appPricePoints?filter[territory]=USA&limit=200")
            free = [p for p in pts if float(p["attributes"].get("customerPrice") or 1) == 0]
            if free:
                do("POST", "/v1/appPriceSchedules", {"data": {"type": "appPriceSchedules", "relationships": {
                    "app": {"data": {"type": "apps", "id": APP}},
                    "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                    "manualPrices": {"data": [{"type": "appPrices", "id": "${price1}"}]}}},
                    "included": [{"type": "appPrices", "id": "${price1}", "attributes": {"startDate": None},
                                  "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free[0]["id"]}}}}]})
            else:
                print("no free USA price point found")
        else:
            print("public record price is not free; price not set")

    # I. public record en-US screenshots -> artifact dir for review
    out = os.environ.get("SHOTS_DIR")
    if out:
        os.makedirs(out, exist_ok=True)
        for loc in get_all(f"/v1/appStoreVersions/{ref_v['id']}/appStoreVersionLocalizations?limit=50"):
            if loc["attributes"]["locale"] != "en-US":
                continue
            for s in get_all(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets?limit=50"):
                dt = s["attributes"]["screenshotDisplayType"]
                for n, shot in enumerate(get_all(f"/v1/appScreenshotSets/{s['id']}/appScreenshots?limit=50")):
                    a = shot["attributes"]
                    asset = a.get("imageAsset") or {}
                    url = (asset.get("templateUrl") or "").replace("{w}", str(asset.get("width"))).replace("{h}", str(asset.get("height"))).replace("{f}", "png")
                    if url:
                        path = f"{out}/{dt}-{n + 1}-{asset.get('width')}x{asset.get('height')}.png"
                        with urllib.request.urlopen(url, timeout=60) as r, open(path, "wb") as f:
                            f.write(r.read())
                        print(f"saved {path} ({a.get('fileName')})")


if __name__ == "__main__":
    main()
