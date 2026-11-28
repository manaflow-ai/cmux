#!/usr/bin/env python3
"""asc_subscription_records.py against a loopback App Store Connect: plan writes
nothing, apply writes only what plan printed, a second apply writes nothing, a
file not checked in yet holds back only its own write, and it never touches a
price, an availability, a retired subscription or one records.json does not
list. Also checks the checked-in records.json and promotional images."""

from __future__ import annotations

import contextlib
import http.server
import io
import json
import os
import struct
import sys
import tempfile
import threading
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "cmux-next-ios" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import app_review_gate as gate  # noqa: E402
import asc_subscription_records as records  # noqa: E402

APP = "6783338052"


def png(path: Path, width: int, height: int, color_type: int = 2) -> None:
    channels = {2: 3, 6: 4}[color_type]
    row = b"\x00" + b"\x80" * (width * channels)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(row * height))
                     + chunk(b"IEND", b""))


class FakeAsc:
    """The subscription endpoints asc_subscription_records.py reads and writes."""

    def __init__(self) -> None:
        self.subs = {
            "com.cmux.app.next_plus.monthly": self.sub("6838160813", "MISSING_METADATA"),
            "com.cmux.app.next_pro.monthly": self.sub("6838160918", "MISSING_METADATA", price=False),
            "com.cmux.app.go.monthly": self.sub("6818445194", "READY_TO_SUBMIT", shot=True, image=True, locale=True),
            "com.cmux.app.pro.trial.monthly": self.sub("6822947304", "READY_TO_SUBMIT"),
        }
        self.requests: list[tuple[str, str, object]] = []
        self.uploads: dict[str, bytes] = {}
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def _body(self) -> bytes:
                return self.rfile.read(int(self.headers.get("Content-Length") or 0))

            def _send(self, status, body):
                raw = json.dumps(body).encode() if body is not None else b""
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                fake.requests.append(("GET", self.path, None))
                self._send(*fake.get(self.path.split("?")[0]))

            def do_POST(self):
                body = json.loads(self._body())
                fake.requests.append(("POST", self.path, body))
                self._send(*fake.post(self.path, body))

            def do_PATCH(self):
                body = json.loads(self._body())
                fake.requests.append(("PATCH", self.path, body))
                self._send(*fake.patch(self.path, body))

            def do_PUT(self):
                fake.uploads[self.path] = self._body()
                fake.requests.append(("PUT", self.path, None))
                self._send(200, None)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @staticmethod
    def sub(sid, state, shot=False, image=False, locale=False, price=True):
        done = {"assetDeliveryState": {"state": "COMPLETE"}}
        return {"id": sid, "state": state, "shot": {"id": f"shot-{sid}", "attributes": done} if shot else None,
                "images": [{"id": f"img-{sid}", "attributes": done}] if image else [],
                "locales": ["en-US"] if locale else [], "price": price}

    def by_id(self, sid):
        return next(s for s in self.subs.values() if s["id"] == sid)

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def get(self, path):
        if path == f"/v1/apps/{APP}/subscriptionGroups":
            return 200, {"data": [{"id": "group-1"}]}
        if path == "/v1/subscriptionGroups/group-1/subscriptions":
            return 200, {"data": [{"id": s["id"], "attributes": {"productId": pid, "state": s["state"]}}
                                  for pid, s in self.subs.items()]}
        parts = path.split("/")
        if len(parts) == 5 and parts[2] == "subscriptions":
            sub, leaf = self.by_id(parts[3]), parts[4]
            if leaf == "appStoreReviewScreenshot":
                return 200, {"data": sub["shot"]}
            if leaf == "images":
                return 200, {"data": sub["images"]}
            if leaf == "subscriptionLocalizations":
                return 200, {"data": [{"id": f"loc-{l}", "attributes": {"locale": l}} for l in sub["locales"]]}
            if leaf == "prices":
                return 200, {"data": [{"id": "price-1"}] if sub["price"] else []}
            if leaf == "subscriptionAvailability":
                return 200, {"data": {"id": "avail-1"}}
        return 404, {"errors": [{"code": "NOT_FOUND"}]}

    def post(self, path, body):
        data = body["data"]
        sid = data["relationships"]["subscription"]["data"]["id"]
        sub = self.by_id(sid)
        if path == "/v1/subscriptionLocalizations":
            sub["locales"].append(data["attributes"]["locale"])
            return 201, {"data": {"id": f"loc-new-{sid}"}}
        if path in ("/v1/subscriptionAppStoreReviewScreenshots", "/v1/subscriptionImages"):
            asset_id = f"{path.rsplit('/', 1)[1]}-{sid}"
            asset = {"id": asset_id, "attributes": {"assetDeliveryState": {"state": "AWAITING_UPLOAD"}}}
            if path.endswith("Screenshots"):
                sub["shot"] = asset
            else:
                sub["images"].append(asset)
            size = data["attributes"]["fileSize"]
            return 201, {"data": {"id": asset_id, "attributes": {"uploadOperations": [
                {"method": "PUT", "url": f"{self.url}/upload/{asset_id}", "offset": 0, "length": size,
                 "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]}]}}}
        return 404, {"errors": [{"code": "NOT_FOUND"}]}

    def patch(self, path, body):
        for sub in self.subs.values():
            for asset in [sub["shot"], *sub["images"]]:
                if asset and path.endswith("/" + asset["id"]) and body["data"]["attributes"].get("uploaded"):
                    asset["attributes"]["assetDeliveryState"] = {"state": "COMPLETE"}
                    return 200, {"data": {"id": asset["id"]}}
        return 404, {"errors": [{"code": "NOT_FOUND"}]}


class RecordsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeAsc()
        self.addCleanup(self.fake.close)
        env = {"CMUX_ASC_API_BASE_URL": self.fake.url, "CMUX_ASC_TEST_TOKEN": "t", "ASC_TIMEOUT_SECONDS": "5"}
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        self.addCleanup(lambda: [os.environ.pop(k) if v is None else os.environ.__setitem__(k, v)
                                 for k, v in old.items()])
        self.dir = Path(tempfile.mkdtemp())
        png(self.dir / "promo-plus.png", 1024, 1024)
        png(self.dir / "promo-pro.png", 1024, 1024)
        png(self.dir / "review.png", 1290, 2796)
        self.body = {
            "subscriptions": [
                {"productId": "com.cmux.app.next_plus.monthly", "reviewScreenshot": "review.png",
                 "promotionalImage": "promo-plus.png", "localizations": {"en-US": {"name": "cmux Plus"}}},
                {"productId": "com.cmux.app.next_pro.monthly", "reviewScreenshot": "review.png",
                 "promotionalImage": "promo-pro.png", "localizations": {"en-US": {"name": "cmux Pro"}}},
            ],
            "retired": [{"productId": "com.cmux.app.pro.trial.monthly", "id": "6822947304", "why": "unused"}],
        }
        self.write_records()

    def write_records(self) -> None:
        (self.dir / "records.json").write_text(json.dumps(self.body))

    def main(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = records.main([*args, "--app", APP, "--records", str(self.dir / "records.json"),
                                 "--json", str(self.dir / "summary.json")])
        return code, out.getvalue()

    def writes(self) -> list[tuple[str, str, object]]:
        return [r for r in self.fake.requests if r[0] != "GET"]

    def test_plan_prints_the_writes_and_writes_nothing(self) -> None:
        code, out = self.main()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.writes(), [])
        self.assertEqual(out.count("plan: "), 6, out)
        self.assertIn("plan: upload promotionalImage promo-plus.png", out)
        self.assertIn("plan: create localization en-US ('cmux Pro')", out)
        self.assertIn("person: no price", out)
        self.assertEqual(json.loads((self.dir / "summary.json").read_text())["planned"], 6)

    def test_apply_writes_once_then_is_a_no_op(self) -> None:
        code, out = self.main("apply")
        self.assertEqual(code, 0, out)
        posts = [r[1] for r in self.writes() if r[0] == "POST"]
        self.assertEqual(sorted(posts), sorted(["/v1/subscriptionAppStoreReviewScreenshots"] * 2
                                               + ["/v1/subscriptionImages"] * 2
                                               + ["/v1/subscriptionLocalizations"] * 2))
        self.assertEqual(self.fake.uploads["/upload/subscriptionImages-6838160813"],
                         (self.dir / "promo-plus.png").read_bytes())
        before = len(self.writes())
        code, out = self.main("apply")
        self.assertEqual(code, 0, out)
        self.assertEqual(len(self.writes()), before, "a second apply wrote again")
        self.assertIn("0 write(s)", out)

    def test_never_writes_price_availability_retired_or_unlisted(self) -> None:
        self.main("apply")
        for method, path, body in self.writes():
            self.assertNotIn("price", path.lower())
            self.assertNotIn("availab", path.lower())
            ids = json.dumps(body or {})
            for unlisted in ("6822947304", "6818445194"):
                self.assertNotIn(unlisted, ids + path, (method, path))

    def test_a_file_not_checked_in_holds_back_only_its_write(self) -> None:
        (self.dir / "review.png").unlink()
        code, out = self.main("apply")
        self.assertEqual(code, 0, out)
        self.assertIn("waiting: reviewScreenshot review.png is not checked in", out)
        posts = [r[1] for r in self.writes() if r[0] == "POST"]
        self.assertNotIn("/v1/subscriptionAppStoreReviewScreenshots", posts)
        self.assertEqual(posts.count("/v1/subscriptionImages"), 2)

    def test_a_wrong_promotional_image_stops_before_any_request(self) -> None:
        png(self.dir / "promo-plus.png", 1024, 1024, color_type=6)
        code, out = self.main("apply")
        self.assertEqual(code, 1)
        self.assertIn("1024x1024 RGB with no alpha", out)
        self.assertEqual(self.fake.requests, [])

    def test_retired_and_listed_is_refused(self) -> None:
        self.body["retired"].append({"productId": "com.cmux.app.next_plus.monthly", "why": "x"})
        self.write_records()
        code, out = self.main()
        self.assertEqual(code, 1)
        self.assertIn("retired and listed", out)


class CheckedInTests(unittest.TestCase):
    def test_checked_in_records_and_images_are_valid(self) -> None:
        body = records.load_records()
        self.assertEqual(records.check_inputs(body), [])
        promos = [sub["promotionalImage"] for sub in body["subscriptions"]]
        self.assertEqual(len(set(promos)), len(promos), "each subscription needs its own promotional image")
        for name in promos:
            self.assertEqual(records.png_info(records.RECORDS_DIR / name), (1024, 1024, 2), name)

    def test_retired_ids_match_the_gate(self) -> None:
        retired = {r["id"]: r["productId"] for r in records.load_records()["retired"]}
        self.assertEqual(retired, gate.RETIRED_SUBSCRIPTIONS)


if __name__ == "__main__":
    unittest.main()
