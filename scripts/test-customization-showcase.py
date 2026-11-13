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
    ids = [sample["id"] for sample in samples]
    assert len(ids) == len(set(ids)), ids
    for sample in samples:
        assert sample["title"] and "\n" in sample["description"], sample["id"]
        assert len(sample["gallery"]) >= 3, sample["id"]
        for key in ("file", "manifest"):
            assert (ROOT / sample[key]).exists(), (sample["id"], key, sample[key])
        if sample.get("install") == "app-store":
            assert sample.get("app"), sample["id"]
    assert len(catalog["apiGaps"]) >= 4
    print(f"customization showcase: {len(samples)} samples, {len(catalog['apiGaps'])} API gaps")


if __name__ == "__main__":
    main()
