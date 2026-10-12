#!/usr/bin/env python3
"""Copies the reviewed What's New documents into the app bundle resources.

whats-new/<version>.json (stable and rc; nightly digests ship in the signed
release notes instead) goes to
Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/WhatsNew/, with
index.json listing the versions. Media is bundled for the newest
MEDIA_VERSIONS versions only; older media loads from cmux.com/whats-new/.
Only documents that pass validate.py are copied.

  sync-app-bundle.py           write the bundle copy
  sync-app-bundle.py --check   exit 1 when the bundle copy is stale
"""
import filecmp, json, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(ROOT, "whats-new")
BUNDLE = os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/WhatsNew")
MEDIA_VERSIONS = 3
sys.path.insert(0, HERE)
import validate  # noqa: E402


def sort_key(version):
    match = validate.VERSION.match(version)
    major, minor, patch, kind, number = match.groups()
    return (int(major), int(minor), int(patch), 0 if kind else 1, int(number or 0))


def build(out):
    versions, problems = [], []
    if os.path.isdir(SOURCE):
        for name in sorted(os.listdir(SOURCE)):
            if not name.endswith(".json"):
                continue
            path = os.path.join(SOURCE, name)
            found = validate.validate_file(path, SOURCE)
            if found:
                problems.extend(found)
                continue
            with open(path, encoding="utf-8") as f:
                document = json.load(f)
            if document["channel"] == "nightly":
                continue
            versions.append(document["version"])
            shutil.copyfile(path, os.path.join(out, name))
    versions.sort(key=sort_key, reverse=True)
    for version in versions[:MEDIA_VERSIONS]:
        media = os.path.join(SOURCE, "media", version)
        if os.path.isdir(media):
            shutil.copytree(media, os.path.join(out, "media", version))
    with open(os.path.join(out, "index.json"), "w", encoding="utf-8") as f:
        json.dump({"versions": versions}, f, indent=2)
        f.write("\n")
    return problems


def same_tree(a, b):
    comparison = filecmp.dircmp(a, b)
    if comparison.left_only or comparison.right_only or comparison.diff_files or comparison.funny_files:
        return False
    _, mismatch, errors = filecmp.cmpfiles(a, b, comparison.common_files, shallow=False)
    return not mismatch and not errors and all(same_tree(os.path.join(a, d), os.path.join(b, d)) for d in comparison.common_dirs)


def main(argv):
    check = "--check" in argv
    with tempfile.TemporaryDirectory() as tmp:
        problems = build(tmp)
        for line in problems:
            print(f"skipped (invalid): {line}", file=sys.stderr)
        if check:
            if not os.path.isdir(BUNDLE) or not same_tree(tmp, BUNDLE):
                print("the bundled What's New copy is stale: run scripts/whats-new/sync-app-bundle.py", file=sys.stderr)
                return 1
            print("ok: bundled What's New copy is current")
            return 0
        if os.path.isdir(BUNDLE):
            shutil.rmtree(BUNDLE)
        shutil.copytree(tmp, BUNDLE)
        print(f"wrote {os.path.relpath(BUNDLE, ROOT)}")
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
