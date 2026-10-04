#!/usr/bin/env python3
"""Writes the R2 fields of a cmux CEF manifest (scripts/cmux-next/cef-manifest.json).

Usage: cef_manifest_r2.py <manifest> <bucket> < "<asset> <sha256> <r2 key>" lines
(the output of publish-cef-r2.sh). Every artifact of the manifest gets its
fields: the top-level (arm64) one gets r2_bucket, r2_key and debug_r2_key; the
"x86_64" object gets r2_key and debug_r2_key. A field that is missing (a new
pin) is added after its sha256. A manifest sha256 that was not published fails.
"""
import json
import sys


def update(artifact, found, bucket=None):
    out = {}
    for k, v in artifact.items():
        if k in ("r2_bucket", "r2_key", "debug_r2_key"):
            continue
        out[k] = v
        if k == "sha256":
            if bucket is not None:
                out["r2_bucket"] = bucket
            sha, key = found.get(artifact.get("asset"), (None, None))
            if sha != artifact["sha256"]:
                sys.exit("manifest asset %s was not published with sha256 %s"
                         % (artifact.get("asset"), artifact["sha256"]))
            out["r2_key"] = key
        if k == "debug_sha256" and artifact.get("debug_asset") in found:
            sha, key = found[artifact["debug_asset"]]
            if sha != artifact["debug_sha256"]:
                sys.exit("manifest debug asset %s sha256 differs from the published one"
                         % artifact["debug_asset"])
            out["debug_r2_key"] = key
    return out


def main():
    path, bucket = sys.argv[1], sys.argv[2]
    with open(path) as f:
        data = json.load(f)
    found = {}
    for line in sys.stdin:
        if line.strip():
            name, sha, key = line.split()
            found[name] = (sha, key)
    out = update(data, found, bucket)
    if isinstance(data.get("x86_64"), dict):
        out["x86_64"] = update(data["x86_64"], found)
    with open(path, "w") as f:
        f.write(json.dumps(out, indent=2) + "\n")
    print("==> updated", path, file=sys.stderr)


if __name__ == "__main__":
    main()
