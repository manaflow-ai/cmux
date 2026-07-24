#!/usr/bin/env python3
import importlib.util
import hashlib
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/ci/validate_release_appcast_assets.py"
SPEC = importlib.util.spec_from_file_location("validate_release_appcast_assets", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def appcast(*, tag: str = "v0.64.20", build: int = 100, asset: str = "cmux-macos.dmg", length: int = 123) -> bytes:
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
  <sparkle:version>{build}</sparkle:version>
  <sparkle:shortVersionString>0.64.20</sparkle:shortVersionString>
  <enclosure
    url="https://github.com/manaflow-ai/cmux/releases/download/{tag}/{asset}"
    length="{length}"
    type="application/octet-stream"
    sparkle:edSignature="signed" />
  </item></channel>
</rss>'''.encode()


class ReleaseAppcastValidationTests(unittest.TestCase):
    def assets(
        self,
        *,
        appcast_data: bytes | None = None,
        include_dmg: bool = True,
        size: int = 123,
    ) -> dict[str, object]:
        appcast_data = appcast() if appcast_data is None else appcast_data
        values = [{
            "name": "appcast.xml",
            "size": len(appcast_data),
            "digest": f"sha256:{hashlib.sha256(appcast_data).hexdigest()}",
        }]
        if include_dmg:
            values.append({"name": "cmux-macos.dmg", "size": size})
        return {"assets": values}

    def test_valid_single_full_release(self) -> None:
        appcast_data = appcast()
        candidate = MODULE.parse_candidate(appcast_data, tag="v0.64.20")
        MODULE.validate_release_assets(
            candidate,
            appcast_data=appcast_data,
            assets_document=self.assets(appcast_data=appcast_data),
            expected_enclosure="cmux-macos.dmg",
        )
        self.assertEqual(candidate.build, 100)

    def test_local_artifact_must_match_enclosure_length(self) -> None:
        candidate = MODULE.parse_candidate(appcast(length=3), tag="v0.64.20")
        with tempfile.TemporaryDirectory() as directory:
            artifact = pathlib.Path(directory) / "cmux-macos.dmg"
            artifact.write_bytes(b"dmg")
            MODULE.validate_local_enclosure(
                candidate,
                enclosure_file=artifact,
                expected_enclosure="cmux-macos.dmg",
            )
            artifact.write_bytes(b"wrong")
            with self.assertRaises(MODULE.ValidationError):
                MODULE.validate_local_enclosure(
                    candidate,
                    enclosure_file=artifact,
                    expected_enclosure="cmux-macos.dmg",
                )

    def test_missing_dmg_is_rejected(self) -> None:
        candidate = MODULE.parse_candidate(appcast(), tag="v0.64.20")
        with self.assertRaises(MODULE.ValidationError):
            MODULE.validate_release_assets(
                candidate,
                appcast_data=appcast(),
                assets_document=self.assets(include_dmg=False),
                expected_enclosure="cmux-macos.dmg",
            )

    def test_wrong_tag_and_length_are_rejected(self) -> None:
        with self.assertRaises(MODULE.ValidationError):
            MODULE.parse_candidate(appcast(tag="v0.64.19"), tag="v0.64.20")

        candidate = MODULE.parse_candidate(appcast(length=124), tag="v0.64.20")
        with self.assertRaises(MODULE.ValidationError):
            MODULE.validate_release_assets(
                candidate,
                appcast_data=appcast(length=124),
                assets_document=self.assets(appcast_data=appcast(length=124), size=123),
                expected_enclosure="cmux-macos.dmg",
            )

    def test_github_appcast_digest_must_match_local_bytes(self) -> None:
        appcast_data = appcast()
        candidate = MODULE.parse_candidate(appcast_data, tag="v0.64.20")
        assets = self.assets(appcast_data=appcast_data)
        assets["assets"][0]["digest"] = "sha256:" + ("0" * 64)

        with self.assertRaises(MODULE.ValidationError):
            MODULE.validate_release_assets(
                candidate,
                appcast_data=appcast_data,
                assets_document=assets,
                expected_enclosure="cmux-macos.dmg",
            )

    def test_malformed_duplicate_length_is_rejected(self) -> None:
        malformed = appcast().replace(b'length="123"', b'length="123" length="123"')
        with self.assertRaises(MODULE.ValidationError):
            MODULE.parse_candidate(malformed, tag="v0.64.20")

    def test_lower_candidate_build_is_rejected_and_higher_build_is_allowed(self) -> None:
        candidate = MODULE.parse_candidate(appcast(build=99), tag="v0.64.20")
        current = MODULE.parse_current_release(appcast(build=100))
        with self.assertRaises(MODULE.ValidationError):
            MODULE.validate_publication_order(
                candidate,
                current,
                allow_missing_current_feed=False,
            )

        higher = MODULE.parse_candidate(appcast(build=101), tag="v0.64.20")
        MODULE.validate_publication_order(
            higher,
            current,
            allow_missing_current_feed=False,
        )

    def test_equal_build_with_different_version_is_not_the_same_release(self) -> None:
        current = MODULE.parse_current_release(appcast(build=100))
        candidate_data = appcast(tag="v0.64.21", build=100).replace(b"0.64.20", b"0.64.21")
        candidate = MODULE.parse_candidate(candidate_data, tag="v0.64.21")

        with self.assertRaises(MODULE.ValidationError):
            MODULE.validate_publication_order(
                candidate,
                current,
                allow_missing_current_feed=False,
            )

    def test_equal_build_and_version_is_allowed_for_exact_repair(self) -> None:
        candidate = MODULE.parse_candidate(appcast(), tag="v0.64.20")
        current = MODULE.parse_current_release(appcast())
        MODULE.validate_publication_order(
            candidate,
            current,
            allow_missing_current_feed=False,
        )

    def test_missing_current_feed_requires_explicit_repair(self) -> None:
        candidate = MODULE.parse_candidate(appcast(), tag="v0.64.20")
        with self.assertRaises(MODULE.ValidationError):
            MODULE.validate_publication_order(
                candidate,
                None,
                allow_missing_current_feed=False,
            )
        MODULE.validate_publication_order(
            candidate,
            None,
            allow_missing_current_feed=True,
        )

    def test_multiple_items_are_rejected(self) -> None:
        data = appcast()
        item_start = data.index(b"<item>")
        item_end = data.index(b"</item>") + len(b"</item>")
        duplicated = data.replace(b"</channel>", data[item_start:item_end] + b"</channel>")
        with self.assertRaises(MODULE.ValidationError):
            MODULE.parse_candidate(duplicated, tag="v0.64.20")

    def test_multiple_enclosures_are_rejected(self) -> None:
        data = appcast()
        enclosure_start = data.index(b"<enclosure")
        enclosure_end = data.index(b"/>", enclosure_start) + len(b"/>")
        enclosure = data[enclosure_start:enclosure_end]
        duplicated = data.replace(enclosure, enclosure + enclosure)
        with self.assertRaises(MODULE.ValidationError):
            MODULE.parse_candidate(duplicated, tag="v0.64.20")


if __name__ == "__main__":
    unittest.main()
