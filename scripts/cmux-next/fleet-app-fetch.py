#!/usr/bin/env python3
"""Fetch a finished fleet `cmux` build's app zip by its artifact sha256 and unpack it (measurement scratch tool).

    fleet-app-fetch.py --sha256 HEX --dest DIR   # prints the unpacked .app path

The controller's artifact store gives a signed URL for sha256:HEX (tailnet only, as ensure-cua-pinned-asset.sh); the
zip is checked against HEX before it is unpacked. $CI_SHARED_CACHE_DIR/fleet-app-fetch/<HEX>/ keeps the unpacked app
for later steps on the same worker.
"""
import argparse, glob, hashlib, json, os, shutil, subprocess, sys, urllib.request

CONTROLLER = os.environ.get("CMUX_CEF_STORE_URL", "http://100.89.225.106:18765").rstrip("/")


def fetch(sha, dest):
    cache_root = os.environ.get("CI_SHARED_CACHE_DIR")
    cached = os.path.join(cache_root, "fleet-app-fetch", sha) if cache_root else None
    if cached and os.path.exists(os.path.join(cached, "ok")):
        apps = glob.glob(os.path.join(cached, "*.app"))
        if apps:
            os.makedirs(dest, exist_ok=True)
            target = os.path.join(dest, os.path.basename(apps[0]))
            if not os.path.exists(target):
                subprocess.run(["ditto", apps[0], target], check=True)
            print(f"fleet-app-fetch: {sha[:12]} from the worker cache", file=sys.stderr)
            return target
    with urllib.request.urlopen(f"{CONTROLLER}/v1/artifacts/sha256:{sha}/url", timeout=30) as reply:
        url = json.load(reply)["url"]
    os.makedirs(dest, exist_ok=True)
    zip_path = os.path.join(dest, f"{sha}.zip")
    subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "3", "--max-time", "1200",
                    "-o", zip_path, url], check=True)
    digest = hashlib.sha256()
    with open(zip_path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != sha:
        sys.exit(f"fleet-app-fetch: {zip_path} is {digest.hexdigest()}, not {sha}")
    unpack = os.path.join(dest, f"unpack-{sha[:12]}")
    shutil.rmtree(unpack, ignore_errors=True)
    subprocess.run(["ditto", "-x", "-k", zip_path, unpack], check=True)
    os.remove(zip_path)
    apps = glob.glob(os.path.join(unpack, "*.app"))
    if len(apps) != 1:
        sys.exit(f"fleet-app-fetch: {sha[:12]} holds {apps}, not one app")
    target = os.path.join(dest, os.path.basename(apps[0]))
    shutil.rmtree(target, ignore_errors=True)
    os.rename(apps[0], target)
    shutil.rmtree(unpack, ignore_errors=True)
    if cached:
        try:
            shutil.rmtree(cached, ignore_errors=True)
            os.makedirs(cached)
            subprocess.run(["ditto", target, os.path.join(cached, os.path.basename(target))], check=True)
            open(os.path.join(cached, "ok"), "w").close()
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"fleet-app-fetch: no cache copy ({error})", file=sys.stderr)
    return target


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--dest", required=True)
    opts = parser.parse_args()
    print(fetch(opts.sha256.removeprefix("sha256:"), os.path.abspath(opts.dest)))
