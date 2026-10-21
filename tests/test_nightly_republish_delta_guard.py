#!/usr/bin/env python3
"""A nightly's delta result republishes when the channel tag is still at its build.

republish-nightly-deltas puts this run's Sparkle delta and its two-item appcast
on the feed, unless a newer publish has moved the channel tag past this build
(a stale result must not overwrite a newer feed). The full feed that
publish-nightly writes holds one item, so a skipped republish leaves the feed
without the previous item and its delta (cx-urd.67).

The nightly-next track's tag shares its name with the `nightly-next` branch,
which the promote job moves ahead while a build runs. `commits/nightly-next`
resolves to the branch, so the guard must read the tag itself
(`git/ref/tags/...`, peeling an annotated tag).

This test renders the step's script the way the runner does and runs it with a
fake `gh` whose branch and tag of that name point at different commits. No
deltas are downloaded, so a step that passes the guard reports that none were
generated and publishes nothing.
"""

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NIGHTLY = os.path.join(ROOT, ".github", "workflows", "nightly.yml")
REPO = "manaflow-ai/cmux"
TAG = "nightly-next"
BUILD = "1" * 40
BRANCH = "2" * 40
NEWER = "3" * 40
TAG_OBJECT = "4" * 40
NIGHTLY_BUILD = "3917159104301"
FAILURES = []

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
jq = None
if "--jq" in args:
    i = args.index("--jq"); jq = args[i + 1]; del args[i:i + 2]
assert args[0] == "api", args
routes = json.loads(os.environ["FAKE_GH_ROUTES"])
path = args[1]
if path == "rate_limit":
    # Quota left: the wrapper waits its short secondary-limit wait (GH_QUOTA_MAX_WAIT).
    print("4999" if jq and "remaining" in jq else "0"); sys.exit(0)
limited = os.environ.get("FAKE_GH_LIMIT_ONCE_DIR")
if limited and path in os.environ.get("FAKE_GH_LIMIT_ONCE", "").split():
    marker = os.path.join(limited, path.replace("/", "_"))
    if not os.path.exists(marker):
        open(marker, "w").close()
        # gh prints the error body on stdout and the message on stderr.
        print('{"message":"API rate limit exceeded for installation."}')
        sys.stderr.write("gh: API rate limit exceeded for installation. (HTTP 403)\n"); sys.exit(1)
if path not in routes:
    sys.stderr.write(f"gh: Not Found (HTTP 404) {path}\n"); sys.exit(1)
body = json.dumps(routes[path])
if jq is None:
    print(body)
else:
    sys.stdout.write(subprocess.run(["jq", "-r", jq], input=body, capture_output=True, text=True, check=True).stdout)
'''


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def render(text, context):
    """Substitute `${{ expr }}` like the runner: known paths get their value,
    anything else becomes empty."""
    return re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", lambda m: context.get(m.group(1).strip(), ""), str(text))


def run_guard(script, tag_object, live_build=None, limit_once=()):
    """Runs the step with the branch at BRANCH and the tag as `tag_object`;
    with `live_build`, the NEXT feed (a file URL) serves that build."""
    routes = {
        # GitHub's commits API resolves the name to the branch.
        f"repos/{REPO}/commits/{TAG}": {"sha": BRANCH},
        f"repos/{REPO}/branches/{TAG}": {"commit": {"sha": BRANCH}},
        f"repos/{REPO}/git/ref/heads/{TAG}": {"ref": f"refs/heads/{TAG}", "object": {"sha": BRANCH, "type": "commit"}},
        f"repos/{REPO}/git/ref/tags/{TAG}": {"ref": f"refs/tags/{TAG}", "object": tag_object},
        f"repos/{REPO}/git/tags/{TAG_OBJECT}": {"sha": TAG_OBJECT, "object": {"sha": BUILD, "type": "commit"}},
    }
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = os.path.join(tmp, "bin")
        os.mkdir(bin_dir)
        gh = os.path.join(bin_dir, "gh")
        with open(gh, "w", encoding="utf-8") as handle:
            handle.write(FAKE_GH)
        os.chmod(gh, os.stat(gh).st_mode | stat.S_IEXEC)
        os.mkdir(os.path.join(tmp, "nightly-deltas"))
        output = os.path.join(tmp, "github-output")
        open(output, "w").close()
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_GH_ROUTES=json.dumps(routes),
                   GITHUB_REPOSITORY=REPO, GITHUB_OUTPUT=output, CHANNEL_RELEASE_TAG=TAG, GH_TOKEN="test",
                   NIGHTLY_BUILD=NIGHTLY_BUILD)
        if limit_once:
            # The checked-out build commit has the quota wrapper; one tag read hits the limit.
            os.makedirs(os.path.join(tmp, "scripts", "ci"))
            shutil.copy(os.path.join(ROOT, "scripts", "ci", "gh-quota-retry.sh"), os.path.join(tmp, "scripts", "ci"))
            os.mkdir(os.path.join(tmp, "limited"))
            env.update(FAKE_GH_LIMIT_ONCE=" ".join(limit_once), FAKE_GH_LIMIT_ONCE_DIR=os.path.join(tmp, "limited"),
                       GH_QUOTA_MAX_WAIT="1")
        if live_build is not None:
            feed = os.path.join(tmp, "feed")
            os.mkdir(feed)
            with open(os.path.join(feed, "appcast-arm64.xml"), "w", encoding="utf-8") as handle:
                handle.write('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                             f'<item><sparkle:version>{live_build}</sparkle:version></item></channel></rss>')
            env["CHANNEL_FEED_BASE"] = f"file://{feed}"
        result = subprocess.run(["bash", "-e", "-c", script], cwd=tmp, env=env, capture_output=True, text=True)
        with open(output, encoding="utf-8") as handle:
            return result, handle.read()


def main():
    if shutil.which("jq") is None:
        print("FAIL: jq is required (the fake gh applies --jq with it)")
        return 1
    workflow = yaml.safe_load(open(NIGHTLY, encoding="utf-8"))
    step = next(s for s in workflow["jobs"]["republish-nightly-deltas"]["steps"] if s.get("id") == "republish")
    script = render(step["run"], {"needs.resolve-nightly-cmux-tui-client.outputs.build_sha": BUILD})

    for label, tag_object in (
        ("a lightweight tag", {"sha": BUILD, "type": "commit"}),
        ("an annotated tag", {"sha": TAG_OBJECT, "type": "tag"}),
    ):
        result, output = run_guard(script, tag_object)
        _check(result.returncode == 0, f"{label} at this build: the step succeeds ({result.stderr.strip()})")
        _check("Skipping stale delta result" not in result.stdout,
               f"{label} at this build, branch moved ahead: the delta result is not called stale ({result.stdout.strip()})")
        _check("No Sparkle deltas were generated" in result.stdout,
               f"{label} at this build: the step goes on to the deltas ({result.stdout.strip()})")

    # 2026-10-21 (run 39536149802): the tag read hit the API quota. The wrapper
    # runs it again, and the failed attempt's error body must not reach the
    # captured tag object (it would read as a stale tag and drop the deltas).
    result, output = run_guard(script, {"sha": TAG_OBJECT, "type": "tag"},
                               limit_once=(f"repos/{REPO}/git/ref/tags/{TAG}", f"repos/{REPO}/git/tags/{TAG_OBJECT}"))
    _check(result.returncode == 0 and "No Sparkle deltas were generated" in result.stdout
           and "Skipping stale delta result" not in result.stdout and "rate limit" in result.stderr,
           f"a rate-limited tag read: the wrapper runs it again and the step goes on to the deltas ({result.stdout.strip()} | {result.stderr.strip()[-300:]})")

    result, output = run_guard(script, {"sha": NEWER, "type": "commit"})
    _check(result.returncode == 0 and "Skipping stale delta result" in result.stdout and "publish=false" in output,
           f"a tag moved to a newer build: the stale result is skipped ({result.stdout.strip()})")

    # The NEXT feed must still serve this build: a newer publication, or a
    # pull by nightly-next-rollback.yml (an older build on top), skips it.
    lightweight = {"sha": BUILD, "type": "commit"}
    result, output = run_guard(script, lightweight, live_build=NIGHTLY_BUILD)
    _check(result.returncode == 0 and "No Sparkle deltas were generated" in result.stdout,
           f"the feed serves this build: the step goes on to the deltas ({result.stdout.strip()})")
    for label, live in (("a newer build", str(int(NIGHTLY_BUILD) + 1)), ("a pulled build's predecessor", str(int(NIGHTLY_BUILD) - 1))):
        result, output = run_guard(script, lightweight, live_build=live)
        _check(result.returncode == 0 and "Skipping stale delta result" in result.stdout and "publish=false" in output,
               f"the feed serves {label}: the result is skipped ({result.stdout.strip()})")

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("PASS: the delta republish guard reads the channel tag, not a branch of the same name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
