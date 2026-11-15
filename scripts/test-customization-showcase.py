#!/usr/bin/env python3
"""Keep the Settings showcase catalog tied to real copy-paste/installable files."""

import hashlib
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "webviews/src/pages/settings/customizeShowcase.json"


def main() -> None:
    catalog = json.loads(CATALOG.read_text())
    samples = catalog["samples"]
    assert 8 <= len(samples) <= 12, len(samples)
    strings = json.loads((ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextSettingsWindow/Localizable.xcstrings").read_text())["strings"]
    ids = [sample["id"] for sample in samples]
    assert len(ids) == len(set(ids)), ids
    for sample in samples:
        assert sample["title"] and "\n" in sample["description"], sample["id"]
        assert len(sample["gallery"]) >= 3, sample["id"]
        for part in ("title", "description"):
            key = f"settingsPage.customization.sample.{sample['id']}.{part}"
            assert strings[key]["localizations"]["en"]["stringUnit"]["value"] == sample[part], key
        for key in ("file", "manifest"):
            assert (ROOT / sample[key]).exists(), (sample["id"], key, sample[key])
        assert sample["install"] == "extension", sample["id"]
        script = (ROOT / sample["file"]).read_text()
        assert len(script.splitlines()) <= 50, (sample["id"], len(script.splitlines()))
        manifest = json.loads((ROOT / sample["manifest"]).read_text())
        assert manifest["id"].startswith("local/showcase-"), sample["id"]
        assert manifest["runtime"]["main"] == "main.js", sample["id"]
        assert "__cmuxAppExports" in script, sample["id"]
        assert "cmuxConfig." not in script, sample["id"]
    app_ids = [json.loads((ROOT / sample["manifest"]).read_text())["id"] for sample in samples]
    assert len(app_ids) == len(set(app_ids)), app_ids
    # The Settings install command downloads from the pinned ref and refuses a file
    # whose sha256 differs from the catalog, so the catalog must match this tree and,
    # when the ref is in this clone, the ref must serve the same bytes.
    ref = catalog["ref"]
    assert re.fullmatch(r"[0-9a-f]{40}", ref), ref
    have_ref = subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{ref}^{{commit}}"], capture_output=True).returncode == 0
    for sample in samples:
        for key in ("file", "manifest"):
            digest = sample["sha256"][key]
            assert re.fullmatch(r"[0-9a-f]{64}", digest), (sample["id"], key)
            assert hashlib.sha256((ROOT / sample[key]).read_bytes()).hexdigest() == digest, (sample["id"], key, "update sha256 and ref")
            if have_ref:
                pinned = subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:{sample[key]}"], capture_output=True, check=True).stdout
                assert hashlib.sha256(pinned).hexdigest() == digest, (sample["id"], key, f"{ref} serves other bytes")
    assert len(catalog["apiGaps"]) >= 4
    pin = "checked against the pinned ref" if have_ref else "pinned ref not in this clone"
    print(f"customization showcase: {len(samples)} samples, {len(catalog['apiGaps'])} API gaps, sha256 {pin}")


if __name__ == "__main__":
    main()
