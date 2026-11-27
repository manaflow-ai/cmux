#!/usr/bin/env python3
"""Download the publisher's iPhone screenshots and version metadata as a reference ZIP."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import urlencode
from urllib.request import urlopen
from zipfile import ZipFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("ids", type=int, nargs="+", help="numeric App Store IDs")
    parser.add_argument("--country", default="us", help="two-letter storefront code")
    args = parser.parse_args()
    ids = list(dict.fromkeys(args.ids))
    query = urlencode({"id": ",".join(map(str, ids)), "country": args.country})
    lookup = f"https://itunes.apple.com/lookup?{query}"
    with urlopen(lookup, timeout=30) as response:
        apps = {app["trackId"]: app for app in json.load(response)["results"]}
    missing = [str(i) for i in ids if not apps.get(i, {}).get("screenshotUrls")]
    if missing:
        parser.exit(1, f"No iPhone screenshots in the {args.country} storefront for {', '.join(missing)}\n")

    manifest = {"source": lookup, "retrieved_at": datetime.now(timezone.utc).isoformat(), "apps": []}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=args.output.parent) as tmp:
        archive = Path(tmp) / "screenshots.zip"
        with ZipFile(archive, "w") as bundle:
            for app_id in ids:
                app = apps[app_id]
                screenshots = []
                for n, url in enumerate(app["screenshotUrls"], start=1):
                    with urlopen(url, timeout=30) as response:
                        ext = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}.get(
                            response.headers.get_content_type())
                        if not ext:
                            parser.exit(1, f"Unexpected screenshot content type for {url}\n")
                        path = f"{app_id}/{n:02}.{ext}"
                        bundle.writestr(path, response.read())
                    screenshots.append({"file": path, "url": url})
                manifest["apps"].append({"id": app_id, "name": app["trackName"], "version": app["version"],
                                         "store_url": app["trackViewUrl"], "iphone_screenshots": screenshots})
                print(f"{app['trackName']} {app['version']}: {len(screenshots)} iPhone screenshots")
            bundle.writestr("manifest.json", json.dumps(manifest, indent=2) + "\n")
        archive.replace(args.output)


if __name__ == "__main__":
    main()
