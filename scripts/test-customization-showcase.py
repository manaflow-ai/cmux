#!/usr/bin/env python3
"""Keep the Settings showcase catalog tied to real copy-paste/installable files."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "skills/cmux-customization/showcase.json"


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
    assert len(catalog["apiGaps"]) >= 4
    print(f"customization showcase: {len(samples)} samples, {len(catalog['apiGaps'])} API gaps")


if __name__ == "__main__":
    main()
