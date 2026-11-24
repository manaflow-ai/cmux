#!/usr/bin/env python3
"""Tests for scripts/ci/ios_asc_ops.py against a fake App Store Connect (no network, no key)."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_asc_ops", ROOT / "scripts/ci/ios_asc_ops.py")
ops = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ops)
WORKFLOW = ROOT / ".github/workflows/ios-asc-ops.yml"


class FakeClient:
    def __init__(self):
        self.calls = []
        self.decl = {"alcoholTobaccoOrDrugUseOrReferences": "NONE", "unrestrictedWebAccess": False}
        self.detail = None
        self.locs = {"l-en": {"locale": "en-US", "whatsNew": None, "promotionalText": "promo"},
                     "l-de": {"locale": "de-DE", "whatsNew": None, "promotionalText": None}}
        self.reject_whats_new = False

    def get(self, path):
        return self.call("GET", path)

    def call(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "PATCH" and path.startswith("/v1/ageRatingDeclarations/"):
            self.decl.update(body["data"]["attributes"])
            return {}
        if method == "POST" and path == "/v1/appStoreReviewDetails":
            self.detail = {"id": "rd1", "attributes": dict(body["data"]["attributes"])}
            return {}
        if method == "PATCH" and path.startswith("/v1/appStoreReviewDetails/"):
            self.detail["attributes"].update(body["data"]["attributes"])
            return {}
        if method == "PATCH" and path.startswith("/v1/appStoreVersionLocalizations/"):
            if self.reject_whats_new:
                raise SystemExit(f"PATCH {path}: HTTP 409: whatsNew cannot be edited")
            self.locs[path.split("/")[3]].update(body["data"]["attributes"])
            return {}
        if path.startswith("/v1/appStoreVersions/v2/appStoreVersionLocalizations?"):
            return {"data": [{"id": k, "attributes": dict(v)} for k, v in self.locs.items()]}
        if path.startswith("/v1/appStoreVersionLocalizations/"):
            loc_id = path.split("/")[3].split("?")[0]
            return {"data": {"id": loc_id, "attributes": dict(self.locs[loc_id])}}
        if path.startswith("/v1/apps/6791408425/appStoreVersions"):
            return {"data": [{"id": "v1", "attributes": {"versionString": "1.2.0", "appStoreState": "READY_FOR_SALE"}},
                             {"id": "v2", "attributes": {"versionString": "1.3.0",
                                                         "appStoreState": "PREPARE_FOR_SUBMISSION"}}]}
        if path == "/v1/apps/6791408425/appInfos":
            return {"data": [{"id": "i1", "attributes": {"state": "READY_FOR_DISTRIBUTION"}},
                             {"id": "i2", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]}
        if path.endswith("/ageRatingDeclaration"):
            return {"data": {"id": "d-" + path.split("/")[3], "attributes": dict(self.decl)}}
        if path == "/v1/appStoreVersions/v2/appStoreReviewDetail":
            if self.detail is None:
                raise SystemExit(f"GET {path}: HTTP 404: not found")
            return {"data": self.detail}
        if path.startswith("/v1/apps/6791408425?"):
            return {"data": {"attributes": {"name": "cmux INTERNAL", "bundleId": "dev.cmux.app.internal"}}}
        if path.startswith("/v1/reviewSubmissions?"):
            return {"data": [{"id": "s1", "attributes": {"state": "READY_FOR_REVIEW"}}]}
        raise AssertionError(f"unexpected {method} {path}")


def run(argv, client):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = ops.main(argv, client=client)
    return code, json.loads(out.getvalue())


class ReadTest(unittest.TestCase):
    def test_app_info_reads_only(self):
        client = FakeClient()
        code, out = run(["app-info"], client)
        self.assertEqual(code, 0)
        self.assertEqual(out["result"]["app"]["bundleId"], "dev.cmux.app.internal")
        self.assertEqual(len(out["result"]["ageRating"]), 2)
        self.assertEqual({m for m, _, _ in client.calls}, {"GET"})

    def test_submissions(self):
        _, out = run(["submissions"], FakeClient())
        self.assertEqual(out["result"]["submissions"][0]["state"], "READY_FOR_REVIEW")

    def test_get_refuses_non_api_path(self):
        for bad in ("https://evil/x", "/v1/apps/1; rm", "v1/apps"):
            with self.assertRaises(SystemExit):
                run(["get", "--path", bad], FakeClient())

    def test_unknown_app_refused(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            ops.main(["versions", "--app", "123"], client=FakeClient())


class WriteTest(unittest.TestCase):
    def test_age_rating_patch_targets_editable_info_and_reads_back(self):
        client = FakeClient()
        _, out = run(["age-rating-patch", "--attributes", '{"unrestrictedWebAccess": true}'], client)
        patch = [c for c in client.calls if c[0] == "PATCH"]
        self.assertEqual(patch[0][1], "/v1/ageRatingDeclarations/d-i2")
        self.assertFalse(out["result"]["before"]["unrestrictedWebAccess"])
        self.assertTrue(out["result"]["after"]["unrestrictedWebAccess"])

    def test_age_rating_patch_needs_object(self):
        for bad in ("", "[]", "{}", "nope"):
            with self.assertRaises(SystemExit):
                run(["age-rating-patch", "--attributes", bad], FakeClient())

    def test_review_detail_sync_creates_then_patches_and_redacts(self):
        client = FakeClient()
        _, out = run(["review-detail-sync", "--attributes",
                      '{"notes": "hi", "demoAccountPassword": "s3cret", "demoAccountRequired": true}'], client)
        self.assertIsNone(out["result"]["before"])
        self.assertEqual(out["result"]["after"]["notes"], "hi")
        self.assertEqual(out["result"]["after"]["demoAccountPassword"], "<redacted>")
        _, out = run(["review-detail-sync", "--attributes", '{"notes": "two"}'], client)
        self.assertEqual(out["result"]["after"]["notes"], "two")
        self.assertNotIn("s3cret", json.dumps(out))

    def test_review_detail_sync_refuses_unknown_keys(self):
        with self.assertRaises(SystemExit):
            run(["review-detail-sync", "--attributes", '{"bogus": 1}'], FakeClient())

    def test_version_localization_patch_writes_whats_new_and_reads_back(self):
        client = FakeClient()
        _, out = run(["version-localization-patch", "--attributes", '{"whatsNew": "cmux on iPhone."}'], client)
        patch = [c for c in client.calls if c[0] == "PATCH"]
        self.assertEqual(len(patch), 1)
        self.assertEqual(patch[0][1], "/v1/appStoreVersionLocalizations/l-en")
        self.assertEqual(patch[0][2]["data"]["attributes"], {"whatsNew": "cmux on iPhone."})
        self.assertIsNone(out["result"]["before"]["whatsNew"])
        self.assertEqual(out["result"]["after"]["whatsNew"], "cmux on iPhone.")
        self.assertEqual(out["result"]["after"]["promotionalText"], "promo")
        self.assertEqual(out["result"]["version"]["versionString"], "1.3.0")

    def test_version_localization_patch_picks_locale(self):
        client = FakeClient()
        run(["version-localization-patch", "--locale", "de-DE", "--attributes", '{"whatsNew": "x"}'], client)
        self.assertEqual(client.locs["l-de"]["whatsNew"], "x")
        self.assertIsNone(client.locs["l-en"]["whatsNew"])

    def test_version_localization_patch_refuses_other_fields_and_bad_input(self):
        for attrs in ('{"description": "x"}', '{"keywords": "a"}', '{"whatsNew": 3}',
                      json.dumps({"whatsNew": "x" * 4001})):
            with self.assertRaises(SystemExit):
                run(["version-localization-patch", "--attributes", attrs], FakeClient())
        for locale in ("fr-FR", "en US", "../x"):
            with self.assertRaises(SystemExit):
                run(["version-localization-patch", "--locale", locale, "--attributes", '{"whatsNew": "x"}'],
                    FakeClient())

    def test_version_localization_patch_refuses_a_version_on_sale(self):
        client = FakeClient()
        with self.assertRaises(SystemExit):
            run(["version-localization-patch", "--version", "1.2.0", "--attributes", '{"whatsNew": "x"}'], client)
        self.assertFalse([c for c in client.calls if c[0] == "PATCH"])

    def test_version_localization_patch_reports_asc_refusal(self):
        client = FakeClient()
        client.reject_whats_new = True
        with self.assertRaises(SystemExit) as err:
            run(["version-localization-patch", "--attributes", '{"whatsNew": "x"}'], client)
        self.assertIn("HTTP 409", str(err.exception))


class FakeAsc:
    """A stateful App Store Connect with subscription groups, products, prices and localizations."""

    TERRITORIES = ["USA", "JPN", "DEU"]

    def __init__(self, app="6783338052", legacy=True):
        self.app = app
        self.calls = []
        self.n = 0
        self.groups = {}
        self.group_locs = []
        self.subs = {}
        self.locs = {}
        self.prices = []
        self.avail = {}
        self.shots = {}
        if legacy:
            gid = self._new_group("cmux Plans")
            for level, plan in enumerate(("max", "pro", "go"), start=1):
                self._new_sub(gid, f"com.cmux.app.{plan}.monthly", level)
        self.opener = None

    def _id(self):
        self.n += 1
        return str(1000 + self.n)

    def _new_group(self, name):
        gid = self._id()
        self.groups[gid] = name
        return gid

    def _new_sub(self, gid, pid, level):
        sid = self._id()
        self.subs[sid] = {"group": gid, "productId": pid, "groupLevel": level, "state": "MISSING_METADATA",
                          "name": pid}
        return sid

    @staticmethod
    def point(territory, usd):
        return f"pp-{territory}-{usd}"

    def _sub_json(self, sid):
        return {"id": sid, "type": "subscriptions", "attributes": {
            k: v for k, v in self.subs[sid].items() if k != "group"}}

    def get(self, path):
        return self.call("GET", path)

    def call(self, method, path, body=None):
        self.calls.append((method, path, body))
        base = path.split("?")[0]
        query = path.split("?")[1] if "?" in path else ""
        parts = base.strip("/").split("/")
        attrs = (body or {}).get("data", {}).get("attributes", {})
        rels = (body or {}).get("data", {}).get("relationships", {})
        if method == "GET" and base == f"/v1/apps/{self.app}/subscriptionGroups":
            return {"data": [{"id": g, "type": "subscriptionGroups", "attributes": {"referenceName": n}}
                             for g, n in self.groups.items()]}
        if method == "POST" and base == "/v1/subscriptionGroups":
            return {"data": {"id": self._new_group(attrs["referenceName"]), "attributes": attrs}}
        if base.endswith("/subscriptionGroupLocalizations"):
            if method == "POST":
                self.group_locs.append(attrs["locale"])
                return {}
            return {"data": [{"id": l, "attributes": {"locale": l}} for l in self.group_locs]}
        if method == "GET" and len(parts) == 4 and parts[1] == "subscriptionGroups" and parts[3] == "subscriptions":
            return {"data": [self._sub_json(s) for s, v in self.subs.items() if v["group"] == parts[2]]}
        if method == "POST" and base == "/v1/subscriptions":
            sid = self._new_sub(rels["group"]["data"]["id"], attrs["productId"], len(self.subs) + 1)
            return {"data": self._sub_json(sid)}
        if method == "PATCH" and parts[:2] == ["v1", "subscriptions"]:
            if self.subs[parts[2]]["state"] in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_BINARY_APPROVAL"):
                raise SystemExit(f"PATCH {path}: HTTP 409: {{\"errors\":[{{\"code\":"
                                 f"\"ENTITY_ERROR.ATTRIBUTE.INVALID.UNMODIFIABLE\"}}]}}")
            self.subs[parts[2]].update(attrs)
            return {}
        if base.endswith("/subscriptionLocalizations") and method == "GET":
            sid = parts[2]
            return {"data": [{"id": f"{sid}-{loc}", "attributes": {"locale": loc, **v}}
                             for loc, v in self.locs.get(sid, {}).items()]}
        if method == "POST" and base == "/v1/subscriptionLocalizations":
            sid = rels["subscription"]["data"]["id"]
            self.locs.setdefault(sid, {})[attrs["locale"]] = {"name": attrs["name"],
                                                              "description": attrs["description"]}
            return {}
        if method == "PATCH" and parts[:2] == ["v1", "subscriptionLocalizations"]:
            sid, loc = parts[2].split("-", 1)
            self.locs[sid][loc].update(attrs)
            return {}
        if base.endswith("/appStoreReviewScreenshot"):
            if parts[2] not in self.shots:
                raise SystemExit(f"GET {path}: HTTP 404: none")
            return {"data": {"id": "shot", "attributes": {"assetDeliveryState": {"state": "COMPLETE"}}}}
        if base.endswith("/subscriptionAvailability"):
            if parts[2] not in self.avail:
                raise SystemExit(f"GET {path}: HTTP 404: none")
            return {"data": {"id": f"av-{parts[2]}", "attributes": {"availableInNewTerritories": True}}}
        if base.endswith("/availableTerritories"):
            return {"data": [{"id": t} for t in self.avail[parts[2][3:]]]}
        if method == "POST" and base == "/v1/subscriptionAvailabilities":
            self.avail[rels["subscription"]["data"]["id"]] = [t["id"] for t in rels["availableTerritories"]["data"]]
            return {}
        if base == "/v1/territories":
            return {"data": [{"id": t} for t in self.TERRITORIES]}
        if base.endswith("/pricePoints"):
            assert "filter[territory]=USA" in query
            # Two pages, to exercise pagination.
            if "page=2" in path:
                return {"data": [{"id": self.point("USA", u), "attributes": {"customerPrice": u}}
                                 for u in ("29.99", "74.99", "299.99", "21.99")]}
            return {"data": [{"id": self.point("USA", "14.99"), "attributes": {"customerPrice": "14.99"}}],
                    "links": {"next": ops.API + base + "?" + query + "&page=2"}}
        if base.endswith("/equalizations"):
            usd = parts[2].rsplit("-", 1)[1]
            return {"data": [{"id": self.point(t, usd), "relationships": {"territory": {"data": {"id": t}}}}
                             for t in self.TERRITORIES if t != "USA"]}
        if base.endswith("/prices") and method == "GET":
            rows = [r for r in self.prices if r["sub"] == parts[2]]
            return {"data": [{"id": f"pr{i}", "attributes": {"startDate": None},
                              "relationships": {"territory": {"data": {"id": r["territory"]}},
                                                "subscriptionPricePoint": {"data": {"id": r["point"]}}}}
                             for i, r in enumerate(rows)],
                    "included": [{"type": "subscriptionPricePoints", "id": r["point"],
                                  "attributes": {"customerPrice": r["point"].rsplit("-", 1)[1]}} for r in rows]}
        if method == "POST" and base == "/v1/subscriptionPrices":
            sid = rels["subscription"]["data"]["id"]
            territory = rels["territory"]["data"]["id"]
            self.prices = [r for r in self.prices if not (r["sub"] == sid and r["territory"] == territory)]
            self.prices.append({"sub": sid, "territory": territory,
                                "point": rels["subscriptionPricePoint"]["data"]["id"]})
            return {}
        raise AssertionError(f"unexpected {method} {path}")


def writes(client):
    return [(m, p) for m, p, _ in client.calls if m != "GET"]


class PriceBookTest(unittest.TestCase):
    def test_sync_creates_next_products_and_reads_back_live(self):
        asc = FakeAsc()
        code, out = run(["price-book-sync", "--app", "6783338052"], asc)
        self.assertEqual(code, 0, out["result"]["errors"])
        after = {s["productId"]: s for g in out["result"]["after"]["groups"] for s in g["subscriptions"]}
        self.assertTrue(out["result"]["after"]["priceBookLive"])
        self.assertEqual(after["com.cmux.app.next_plus.monthly"]["usPrice"], "29.99")
        self.assertEqual(after["com.cmux.app.next_pro.monthly"]["usPrice"], "74.99")
        self.assertEqual(after["com.cmux.app.next_max.monthly"]["usPrice"], "299.99")
        self.assertEqual(after["com.cmux.app.next_plus.monthly"]["territoriesPriced"], 3)
        levels = {pid: s["groupLevel"] for pid, s in after.items()}
        self.assertEqual(levels, {"com.cmux.app.next_max.monthly": 1, "com.cmux.app.next_pro.monthly": 2,
                                  "com.cmux.app.next_plus.monthly": 3, "com.cmux.app.max.monthly": 4,
                                  "com.cmux.app.pro.monthly": 5, "com.cmux.app.go.monthly": 6})
        self.assertEqual(after["com.cmux.app.next_plus.monthly"]["localizations"]["ja"]["description"],
                         "毎月30,000マシン分とChief 1体")
        # The legacy products keep their (absent) prices and text.
        self.assertIsNone(after["com.cmux.app.go.monthly"]["usPrice"])

    def test_sync_is_idempotent(self):
        asc = FakeAsc()
        run(["price-book-sync", "--app", "6783338052"], asc)
        asc.calls.clear()
        code, out = run(["price-book-sync", "--app", "6783338052"], asc)
        self.assertEqual(code, 0)
        self.assertEqual(writes(asc), [])
        self.assertEqual(out["result"]["log"], [])

    def test_sync_skips_levels_of_subscriptions_in_review(self):
        # Run 45106915214: max and pro were WAITING_FOR_REVIEW, so their level PATCH got HTTP 409 UNMODIFIABLE.
        asc = FakeAsc()
        state = {"com.cmux.app.max.monthly": "WAITING_FOR_REVIEW", "com.cmux.app.pro.monthly": "IN_REVIEW",
                 "com.cmux.app.go.monthly": "PENDING_BINARY_APPROVAL"}
        for sub in asc.subs.values():
            sub["state"] = state[sub["productId"]]
        code, out = run(["price-book-sync", "--app", "6783338052"], asc)
        result = out["result"]
        self.assertEqual(code, 0, result["errors"])
        self.assertEqual(result["errors"], [])
        self.assertTrue(result["after"]["priceBookLive"])
        patched = {p for m, p, _ in asc.calls if m == "PATCH" and p.startswith("/v1/subscriptions/")}
        by_pid = {v["productId"]: k for k, v in asc.subs.items()}
        # Known locked states are not even tried; an unknown state's 409 UNMODIFIABLE is a skip too.
        self.assertNotIn(f"/v1/subscriptions/{by_pid['com.cmux.app.max.monthly']}", patched)
        self.assertNotIn(f"/v1/subscriptions/{by_pid['com.cmux.app.pro.monthly']}", patched)
        self.assertIn(f"/v1/subscriptions/{by_pid['com.cmux.app.go.monthly']}", patched)
        self.assertEqual([s.split(":")[0] for s in result["skipped"]],
                         ["com.cmux.app.max.monthly level 4", "com.cmux.app.pro.monthly level 5",
                          "com.cmux.app.go.monthly level 6"])
        self.assertIn("com.cmux.app.max.monthly level 4 skipped: WAITING_FOR_REVIEW", result["log"])
        after = {s["productId"]: s for g in result["after"]["groups"] for s in g["subscriptions"]}
        self.assertEqual(after["com.cmux.app.max.monthly"]["groupLevel"], 1)
        for pid, usd, level in (("next_max", "299.99", 1), ("next_pro", "74.99", 2), ("next_plus", "29.99", 3)):
            self.assertEqual(after[f"com.cmux.app.{pid}.monthly"]["usPrice"], usd)
            self.assertEqual(after[f"com.cmux.app.{pid}.monthly"]["groupLevel"], level)
            self.assertEqual(after[f"com.cmux.app.{pid}.monthly"]["territoriesPriced"], 3)

    def test_sync_still_fails_on_other_level_errors_and_a_missing_price(self):
        asc = FakeAsc()
        real = asc.call

        def call(method, path, body=None):
            if method == "PATCH" and path.startswith("/v1/subscriptions/"):
                raise SystemExit(f"PATCH {path}: HTTP 409: ENTITY_ERROR.ATTRIBUTE.INVALID")
            return real(method, path, body)
        asc.call = call
        code, out = run(["price-book-sync", "--app", "6783338052"], asc)
        self.assertEqual(code, 1)
        self.assertTrue(out["result"]["errors"])
        self.assertEqual(out["result"]["skipped"], [])

        asc = FakeAsc()
        for sub in asc.subs.values():
            sub["state"] = "WAITING_FOR_REVIEW"
        real = asc.call

        def no_prices(method, path, body=None):
            if method == "POST" and path == "/v1/subscriptionPrices":
                return {}
            return real(method, path, body)
        asc.call = no_prices
        code, out = run(["price-book-sync", "--app", "6783338052"], asc)
        self.assertEqual(code, 1)
        self.assertFalse(out["result"]["after"]["priceBookLive"])

    def test_internal_app_gets_a_new_group(self):
        asc = FakeAsc(app="6791408425", legacy=False)
        code, out = run(["price-book-sync", "--app", "6791408425"], asc)
        self.assertEqual(code, 0)
        self.assertEqual(list(asc.groups.values()), ["cmux Plans"])
        self.assertEqual(sorted(asc.group_locs), ["en-US", "ja"])
        pids = sorted(s["productId"] for s in asc.subs.values())
        self.assertEqual(pids, ["dev.cmux.app.internal.next_max.monthly", "dev.cmux.app.internal.next_plus.monthly",
                                "dev.cmux.app.internal.next_pro.monthly"])

    def test_classic_beta_reprices_go_and_fixes_its_text(self):
        asc = FakeAsc(app="6757092429", legacy=False)
        gid = asc._new_group("cmux Plans")
        go = None
        for level, plan in enumerate(("max", "pro", "go"), start=1):
            sid = asc._new_sub(gid, f"dev.cmux.app.beta.{plan}.monthly", level)
            go = sid if plan == "go" else go
        asc.locs[go] = {"en-US": {"name": "cmux Go", "description": "1 Cloud VM, 40 VM-hours a month"}}
        for t in asc.TERRITORIES:
            asc.prices.append({"sub": go, "territory": t, "point": asc.point(t, "14.99")})
        code, out = run(["price-book-sync", "--app", "6757092429"], asc)
        self.assertEqual(code, 0)
        after = {s["productId"]: s for g in out["result"]["after"]["groups"] for s in g["subscriptions"]}
        self.assertEqual(after["dev.cmux.app.beta.go.monthly"]["usPrice"], "21.99")
        self.assertNotIn("VM-hours", json.dumps(after["dev.cmux.app.beta.go.monthly"]["localizations"]))
        self.assertEqual(len(asc.subs), 3)

    def test_subscriptions_read_writes_nothing(self):
        asc = FakeAsc()
        code, out = run(["subscriptions", "--app", "6783338052"], asc)
        self.assertEqual(code, 0)
        self.assertEqual(writes(asc), [])
        self.assertFalse(out["result"]["priceBookLive"])

    def test_review_screenshot_needs_the_file(self):
        with self.assertRaises(SystemExit):
            ops.review_screenshot_sync(FakeAsc(), "6783338052", Path("/nonexistent/paywall.png"))

    def test_price_book_matches_the_server_config(self):
        """PRICE_BOOK equals web/services/billing/apple/config.ts: product IDs and USD list prices."""
        config = ROOT / "web/services/billing/apple/config.ts"
        if not config.is_file():
            self.skipTest("web/services/billing/apple/config.ts not checked out")
        text = config.read_text(encoding="utf-8")
        block = re.search(r"APPLE_USD_LIST_PRICE[^=]*=\s*\{(.*?)\};", text, re.S)
        self.assertIsNotNone(block)
        listed = {k: v for k, v in re.findall(r"(\w+):\s*([0-9.]+)", block.group(1))}
        if "next_plus" not in listed:
            self.skipTest("config.ts predates the NEXT App Store products (cmux#50896)")
        self.assertIn("`${bundleId}.${planId}.${period}`", text)
        for app, products in ops.PRICE_BOOK.items():
            for product in products:
                self.assertEqual(float(listed[product["plan"]]), float(product["usd"]), product["plan"])
                self.assertEqual(ops.product_id(app, product["plan"]), f"{ops.BUNDLES[app]}.{product['plan']}.monthly")
        self.assertEqual(ops.BUNDLES["6783338052"], re.search(r'APP_STORE_BUNDLE_ID = "([^"]+)"', text).group(1))
        self.assertEqual(ops.BUNDLES["6757092429"], re.search(r'CLASSIC_APPLE_BUNDLE_ID = "([^"]+)"', text).group(1))

    def test_texts_fit_app_store_limits(self):
        for products in ops.PRICE_BOOK.values():
            for product in products:
                for locale, (name, description) in product["localizations"].items():
                    self.assertLessEqual(len(name), 30, name)
                    self.assertLessEqual(len(description), 55, description)


class JwtTest(unittest.TestCase):
    def test_der_to_raw(self):
        der = bytes([0x30, 0x08, 0x02, 0x02, 0x00, 0x81, 0x02, 0x02, 0x01, 0x02])
        raw = ops._der_to_raw(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[31], 0x81)
        self.assertEqual(raw[62:], b"\x01\x02")


class WorkflowTest(unittest.TestCase):
    def test_workflow_offers_every_op_and_runs_from_main_only(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        for op in ops.READS + ops.WRITES:
            self.assertIn(f"- {op}", text)
        self.assertIn("environment: release", text)
        self.assertIn("github.ref == 'refs/heads/main'", text)


if __name__ == "__main__":
    unittest.main()
