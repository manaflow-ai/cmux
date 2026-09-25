#!/usr/bin/env python3
"""Compile admission may start from the nightly seed's DerivedData, never be judged by it."""
import json
import os
import re
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import seed_derived_data as seed  # noqa: E402

BUILD_TIME_NS = 1_700_000_000_000_000_000
FAKE_R2 = """#!/usr/bin/env bash
# restore <dir> <key> <prefix>: stands in for scripts/ci/r2-cache.sh.
dir="$2"
[ -z "${FAKE_CALLS:-}" ] || echo "$3" >> "$FAKE_CALLS"
sleep "${FAKE_DELAY:-0}"
echo "cache-hit=false" >> "$GITHUB_OUTPUT"
case "$FAKE_MODE" in
  hit)
    rm -rf "$dir"; mkdir -p "$dir"; tar -xf "$FAKE_ARCHIVE" -C "$dir"
    echo "cache-matched-key=${4}0123abc" >> "$GITHUB_OUTPUT" ;;
  fail) exit 1 ;;
esac
"""


class SeedDerivedData(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.source = self.root / "src"
        (self.source / "Sources").mkdir(parents=True)
        (self.source / "Sources/App.swift").write_text("let app = 1\n")
        (self.source / "Sources/Other.swift").write_text("let other = 1\n")
        for path in self.source.rglob("*.swift"):
            os.utime(path, ns=(BUILD_TIME_NS, BUILD_TIME_NS))
        self.derived = self.root / "derived-data-compile-admission"
        self.fake = self.root / "r2-cache.sh"
        self.fake.write_text(FAKE_R2)
        self.env = dict(os.environ)
        os.environ["CMUX_R2_CACHE_SCRIPT"] = str(self.fake)
        # Seed keys name the Swift job width; pin it so keys do not depend on
        # the machine running the tests.
        os.environ["CMUX_SEED_SWIFT_JOBS"] = "6"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env)

    def publish_seed(self, with_manifest=True):
        """Build the seed the way nightly.yml does: record, build, prune, archive."""
        seed.record(self.source, self.derived)
        (self.derived / "Build").mkdir()
        (self.derived / "Build/App.o").write_text("object")
        (self.derived / "Logs").mkdir()
        (self.derived / "Logs/build.xcactivitylog").write_text("log")
        (self.derived / "Index.noindex").mkdir()
        self.assertEqual(seed.prune(self.derived)["save"], "true")
        self.assertFalse((self.derived / "Logs").exists())
        self.assertFalse((self.derived / "Index.noindex").exists())
        if not with_manifest:
            (self.derived / seed.MANIFEST).unlink()
        archive = self.root / "seed.tar"
        with tarfile.open(archive, "w") as bundle:
            bundle.add(self.derived, arcname=".")
        os.environ["FAKE_ARCHIVE"] = str(archive)
        # The consumer is a fresh runner: fresh DerivedData from resolve, and
        # every checked-out file stamped now.
        import shutil
        shutil.rmtree(self.derived)
        self.derived.mkdir()
        (self.derived / "from-resolve").write_text("resolve")
        for path in self.source.rglob("*.swift"):
            os.utime(path)

    def adopt(self, mode):
        os.environ["FAKE_MODE"] = mode
        # On darwin a hit runs `defaults write com.apple.dt.XCBuild ...`;
        # tests must never change the developer's real Xcode default.
        with mock.patch.object(seed.sys, "platform", "linux"):
            return seed.adopt(self.source, self.derived, "admission-derived-data-v1-x-base", "admission-derived-data-v1-x-")

    def mtime(self, relative):
        return (self.source / relative).stat().st_mtime_ns

    def test_a_hit_swaps_in_the_seed_and_ages_only_unchanged_inputs(self):
        self.publish_seed()
        (self.source / "Sources/App.swift").write_text("let app = 2\n")

        result = self.adopt("hit")

        self.assertEqual(result["hit"], "true")
        self.assertEqual(result["key"], "admission-derived-data-v1-x-0123abc")
        self.assertEqual((result["unchanged_inputs"], result["changed_inputs"]), ("1", "1"))
        self.assertEqual((self.derived / "Build/App.o").read_text(), "object")
        self.assertFalse((self.derived / "from-resolve").exists())
        self.assertEqual(self.mtime("Sources/Other.swift"), BUILD_TIME_NS)
        self.assertGreater(self.mtime("Sources/App.swift"), BUILD_TIME_NS)
        self.assertFalse(self.derived.with_name(self.derived.name + ".seed").exists())

    def test_a_miss_leaves_the_resolved_derived_data_alone(self):
        self.publish_seed()
        result = self.adopt("miss")
        self.assertEqual(result, {"hit": "false", "reason": "no-seed"})
        self.assertEqual((self.derived / "from-resolve").read_text(), "resolve")
        self.assertGreater(self.mtime("Sources/Other.swift"), BUILD_TIME_NS)

    def test_a_seed_without_recorded_inputs_is_refused(self):
        self.publish_seed(with_manifest=False)
        result = self.adopt("hit")
        self.assertEqual(result["reason"], "seed-without-input-manifest")
        self.assertTrue((self.derived / "from-resolve").exists())
        self.assertFalse((self.derived / "Build").exists())
        self.assertFalse(self.derived.with_name(self.derived.name + ".seed").exists())

    def test_a_failed_restore_is_a_cold_build(self):
        self.publish_seed()
        os.environ["FAKE_MODE"] = "fail"
        output = self.root / "output"
        os.environ["GITHUB_OUTPUT"] = str(output)
        with mock.patch.object(seed, "lineage", return_value=["k"]), mock.patch.object(seed, "seed_exists", return_value=False):
            self.assertEqual(seed.main(["seed", "adopt", str(self.source), str(self.derived), "p-", "k"]), 0)
        self.assertIn("hit=false", output.read_text())
        self.assertTrue((self.derived / "from-resolve").exists())

    def start_then_adopt(self, mode, start_args=None):
        """Download in the background, as compile admission does while it resolves."""
        os.environ["FAKE_MODE"] = mode
        os.environ["FAKE_CALLS"] = str(self.root / "calls")
        # No repository and no bucket URL: each revision is its own exact key.
        os.environ.pop("GITHUB_REPOSITORY", None)
        os.environ.pop("CI_CACHE_R2_PUBLIC_URL", None)
        seed.main(["seed", "start", str(self.derived), *(start_args or ("admission-derived-data-v1-x-", "base"))])
        # The resolve step runs meanwhile and rewrites the DerivedData.
        import shutil
        shutil.rmtree(self.derived)
        self.derived.mkdir()
        (self.derived / "from-resolve").write_text("resolve")
        output = self.root / "output"
        output.unlink(missing_ok=True)
        os.environ["GITHUB_OUTPUT"] = str(output)
        with mock.patch.object(seed.sys, "platform", "linux"):
            seed.main(["seed", "adopt", str(self.source), str(self.derived),
                       "admission-derived-data-v1-x-", "base"])
        return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def calls(self):
        return (self.root / "calls").read_text().split()

    def assert_no_leftovers(self):
        leftovers = sorted(p.name for p in self.root.iterdir() if p.name.startswith(self.derived.name + "."))
        self.assertEqual(leftovers, [])

    def test_adopt_waits_for_the_background_download_instead_of_downloading_again(self):
        self.publish_seed()
        (self.source / "Sources/App.swift").write_text("let app = 2\n")
        os.environ["FAKE_DELAY"] = "1"

        result = self.start_then_adopt("hit")

        self.assertEqual(result["hit"], "true")
        self.assertEqual(result["key"], "admission-derived-data-v1-x-j6-0123abc")
        self.assertEqual((result["unchanged_inputs"], result["changed_inputs"]), ("1", "1"))
        self.assertEqual(self.calls(), ["admission-derived-data-v1-x-j6-base"])
        self.assertEqual((self.derived / "Build/App.o").read_text(), "object")
        self.assertFalse((self.derived / "from-resolve").exists())
        self.assertEqual(self.mtime("Sources/Other.swift"), BUILD_TIME_NS)
        self.assert_no_leftovers()

    def test_a_failed_background_download_is_a_cold_build(self):
        self.publish_seed()
        result = self.start_then_adopt("fail")
        self.assertEqual(result["hit"], "false")
        self.assertEqual(self.calls(), ["admission-derived-data-v1-x-j6-base"])
        self.assertEqual((self.derived / "from-resolve").read_text(), "resolve")
        self.assertGreater(self.mtime("Sources/Other.swift"), BUILD_TIME_NS)
        self.assert_no_leftovers()

    def test_a_background_miss_leaves_the_resolved_derived_data_alone(self):
        self.publish_seed()
        result = self.start_then_adopt("miss")
        self.assertEqual(result, {"hit": "false", "reason": "no-seed"})
        self.assertEqual((self.derived / "from-resolve").read_text(), "resolve")
        self.assert_no_leftovers()

    def test_a_killed_background_download_is_downloaded_again(self):
        # A runner that reaps a step's processes when the step ends would
        # kill the download; adopt must not mistake that for a missing seed.
        self.publish_seed()
        os.environ["FAKE_DELAY"] = "30"
        real_start = seed.start

        def start_and_kill(*args):
            real_start(*args)
            ticket = json.loads(self.derived.with_name(self.derived.name + ".seed.ticket").read_text())
            seed.stop(ticket["pid"])
            os.environ["FAKE_DELAY"] = "0"

        with mock.patch.object(seed, "start", start_and_kill):
            result = self.start_then_adopt("hit")
        self.assertEqual(result["hit"], "true")
        self.assertEqual(self.calls()[-1], "admission-derived-data-v1-x-j6-base")
        self.assert_no_leftovers()

    def test_a_download_started_for_other_keys_is_not_adopted(self):
        self.publish_seed()
        result = self.start_then_adopt("hit", ("admission-derived-data-v1-y-", "base"))
        # The stray download is stopped and adopt fetches its own keys.
        self.assertEqual(result["hit"], "true")
        self.assertEqual(result["key"], "admission-derived-data-v1-x-j6-0123abc")
        self.assertEqual(self.calls()[-1], "admission-derived-data-v1-x-j6-base")
        self.assert_no_leftovers()

    def test_adopt_prefers_the_nearest_seeded_ancestor_over_the_newest_pointer(self):
        """The seed of REVISION, or of its nearest ancestor with one, is the exact
        key; only when none has a seed does the newest pointer decide."""
        published = {"p-c3", "p-c1"}
        probed = []

        def exists(key):
            probed.append(key)
            return key in published

        self.assertEqual(seed.nearest("p-", ["c4", "c3", "c2", "c1"], exists), ("p-c3", 1))
        self.assertEqual(sorted(probed), ["p-c1", "p-c2", "p-c3", "p-c4"])
        self.assertEqual(seed.nearest("p-", ["c5", "c4"], exists), None)

        restored = []
        # Through main, keys carry the width (see setUp).
        published = {"p-j6-c3", "p-j6-c1"}
        self.publish_seed()
        os.environ["FAKE_MODE"] = "hit"
        output = self.root / "output"
        os.environ["GITHUB_OUTPUT"] = str(output)
        with mock.patch.object(seed, "lineage", return_value=["c4", "c3", "c1"]), \
                mock.patch.object(seed, "seed_exists", side_effect=lambda key: key in published), \
                mock.patch.object(seed, "adopt", side_effect=lambda *a: restored.append(a) or {"hit": "true", "key": a[2]}):
            self.assertEqual(seed.main(["seed", "adopt", str(self.source), str(self.derived), "p-", "c4"]), 0)
        self.assertEqual(restored[0][2:], ("p-j6-c3", "p-j6-"))
        self.assertIn("seed_distance=1", output.read_text())

        # No seeded ancestor: ask for REVISION's own key, so the restore falls
        # back to the pointer, and say the distance is unknown.
        restored.clear()
        output.write_text("")
        with mock.patch.object(seed, "lineage", return_value=["c9"]), \
                mock.patch.object(seed, "seed_exists", return_value=False), \
                mock.patch.object(seed, "adopt", side_effect=lambda *a: restored.append(a) or {"hit": "true", "key": "p-c1"}):
            seed.main(["seed", "adopt", str(self.source), str(self.derived), "p-", "c9"])
        self.assertEqual(restored[0][2:], ("p-j6-c9", "p-j6-"))
        self.assertIn("seed_distance=\n", output.read_text())

    def test_seed_keys_name_the_swift_job_width(self):
        """Swift Build passes the runner's CPU count to every swift-driver
        invocation as -j<n>, so a seed built on 12 vCPU reruns every
        SwiftDriver task and re-emits every module on 6 vCPU (run 36043267820:
        94 and 62 at seed distance 0). A seed names the width it was built at."""
        os.environ["CMUX_SEED_SWIFT_JOBS"] = "6"
        self.assertEqual(seed.scoped("p-"), "p-j6-")
        self.assertEqual(seed.scoped("p-", 12), "p-j12-")
        output = self.root / "scope"
        with mock.patch.object(seed.sys, "stdout", new=output.open("w")) as stream:
            self.assertEqual(seed.main(["seed", "scope", "p-"]), 0)
            stream.close()
        self.assertEqual(output.read_text().strip(), "p-j6-")

    def test_adopt_prefers_its_own_width_and_falls_back_to_another(self):
        """A seed of the other width still beats a cold build, so it is the
        fallback, never the first choice."""
        os.environ["CMUX_SEED_SWIFT_JOBS"] = "6"
        published = set()
        exists = lambda key: key in published  # noqa: E731
        with mock.patch.object(seed, "lineage", return_value=["c4", "c3"]), \
                mock.patch.object(seed, "seed_exists", side_effect=exists):
            published.update({"p-j12-c4", "p-j6-c3"})
            self.assertEqual(seed.locate("p-", "c4"), ("p-j6-c3", 1))
            published.clear()
            published.add("p-j12-c4")
            self.assertEqual(seed.locate("p-", "c4"), ("p-j12-c4", 0))
            published.clear()
            self.assertEqual(seed.locate("p-", "c4"), ("p-j6-c4", None))

    def test_seed_probe_names_itself_and_treats_any_error_as_a_miss(self):
        os.environ["CI_CACHE_R2_PUBLIC_URL"] = "https://cache.example/"
        os.environ["RUNNER_OS"], os.environ["RUNNER_ARCH"] = "macOS", "ARM64"
        seen = []

        def urlopen(request, timeout):
            seen.append(request)
            raise seed.urllib.error.HTTPError(request.full_url, 404, "missing", {}, None)

        with mock.patch.object(seed.urllib.request, "urlopen", side_effect=urlopen):
            self.assertFalse(seed.seed_exists("p-abc"))
        self.assertEqual(
            [r.full_url for r in seen],
            ["https://cache.example/v1/macOS-ARM64/objects/p-abc.tar.zst",
             "https://cache.example/v1/macOS-ARM64/objects/p-abc.tar.gz"],
        )
        # The CDN refuses urllib's default User-Agent with 403.
        self.assertTrue(all(r.get_method() == "HEAD" for r in seen))
        self.assertTrue(all(r.get_header("User-agent") == seed.USER_AGENT for r in seen))
        with mock.patch.object(seed.urllib.request, "urlopen", side_effect=ValueError("bad status")):
            self.assertFalse(seed.seed_exists("p-abc"))

    def test_lineage_without_a_repository_or_api_is_the_revision_alone(self):
        os.environ.pop("GITHUB_REPOSITORY", None)
        self.assertEqual(seed.lineage("abc"), ["abc"])
        os.environ["GITHUB_REPOSITORY"] = "o/r"
        with mock.patch.object(seed.subprocess, "run", side_effect=OSError("no gh")):
            self.assertEqual(seed.lineage("abc"), ["abc"])
        listed = mock.Mock(stdout="abc\nparent\ngrandparent\n")
        with mock.patch.object(seed.subprocess, "run", return_value=listed):
            self.assertEqual(seed.lineage("abc"), ["abc", "parent", "grandparent"])

    def test_adopt_reuses_the_seed_start_picked_without_probing_again(self):
        """start picks the nearest seed once; adopt for the same PREFIX and
        REVISION waits for that download and reports its distance."""
        self.publish_seed()
        os.environ["FAKE_MODE"] = "hit"
        os.environ["FAKE_CALLS"] = str(self.root / "calls")
        with mock.patch.object(seed, "locate", return_value=("p-c3", 1)) as located:
            seed.main(["seed", "start", str(self.derived), "p-", "c4"])
            output = self.root / "output"
            os.environ["GITHUB_OUTPUT"] = str(output)
            with mock.patch.object(seed.sys, "platform", "linux"):
                seed.main(["seed", "adopt", str(self.source), str(self.derived), "p-", "c4"])
        self.assertEqual(located.call_count, 1)
        self.assertEqual((self.root / "calls").read_text().split(), ["p-c3"])
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(outputs["hit"], "true")
        # The fake restore reports the pointer key, not p-c3, so no distance.
        self.assertEqual(outputs["seed_distance"], "")

    def test_prune_refuses_an_unrecorded_or_oversized_seed(self):
        self.derived.mkdir()
        self.assertEqual(seed.prune(self.derived)["reason"], "no-input-manifest")
        seed.record(self.source, self.derived)
        limit = seed.MAX_RAW_BYTES
        try:
            seed.MAX_RAW_BYTES = 1
            self.assertEqual(seed.prune(self.derived)["reason"], "too-large")
        finally:
            seed.MAX_RAW_BYTES = limit


def load(workflow):
    return yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())


def steps(workflow, job):
    return load(workflow)["jobs"][job]["steps"]


def named(step_list, name):
    matches = [index for index, step in enumerate(step_list) if step.get("name") == name]
    assert len(matches) == 1, name
    return matches[0], step_list[matches[0]]


TOKEN = re.compile(r"\s*(\|\||&&|==|!=|>=|<=|>|<|!|\(|\)|,|'(?:[^']|'')*'|[0-9]+(?:\.[0-9]+)?|[A-Za-z_][A-Za-z0-9_.-]*)")


def evaluate(expression, context):
    """Evaluate the GitHub Actions expression subset these workflows use.

    `a && b` is b when a is truthy, else a; `a || b` is a when truthy,
    else b. Names resolve by dotted path in `context`; a missing one is null,
    which compares equal to ''. startsWith() and endsWith() compare case-insensitively.
    `<`, `>`, `<=` and `>=` compare as numbers, the way Actions coerces: null
    and '' are 0, and a string that is not a number never compares true.
    """
    text = expression.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    tokens, at = [], 0
    while text[at:].strip():
        match = TOKEN.match(text, at)
        if not match:
            raise ValueError(f"cannot parse {text[at:]!r}")
        tokens.append(match.group(1))
        at = match.end()
    position = [0]

    def peek():
        return tokens[position[0]] if position[0] < len(tokens) else None

    def take():
        position[0] += 1
        return tokens[position[0] - 1]

    def primary():
        token = take()
        if token == "(":
            value = either()
            if take() != ")":
                raise ValueError("unbalanced parentheses")
            return value
        if token == "!":
            return not primary()
        if token.startswith("'"):
            return token[1:-1].replace("''", "'")
        if token in ("true", "false"):
            return token == "true"
        if token[0].isdigit():
            return float(token)
        if token == "format" and peek() == "(":
            take()
            template, values = either(), []
            while peek() == ",":
                take()
                value = either()
                values.append(str(int(value)) if isinstance(value, float) and value.is_integer()
                              else "" if value is None else str(value))
            if take() != ")":
                raise ValueError("unbalanced parentheses")
            text = str(template)
            for index, value in enumerate(values):
                text = text.replace("{" + str(index) + "}", value)
            return text
        if token in ("startsWith", "endsWith", "contains") and peek() == "(":
            take()
            haystack = either()
            if take() != ",":
                raise ValueError(f"{token} takes two arguments")
            needle = either()
            if take() != ")":
                raise ValueError("unbalanced parentheses")
            haystack = ("" if haystack is None else str(haystack)).lower()
            needle = ("" if needle is None else str(needle)).lower()
            if token == "startsWith":
                return haystack.startswith(needle)
            return haystack.endswith(needle) if token == "endsWith" else needle in haystack
        value = context
        for part in token.split("."):
            value = value.get(part) if isinstance(value, dict) else None
        return value

    def number(value):
        if value is None or value == "":
            return 0.0
        if isinstance(value, bool):
            return float(value)
        try:
            return float(value)
        except (TypeError, ValueError):
            return float("nan")

    def comparison():
        left = primary()
        while peek() in ("==", "!=", ">", "<", ">=", "<="):
            operator, right = take(), primary()
            if operator in ("==", "!="):
                # Actions compares a number with a string numerically
                # (github.run_attempt == 2), and strings as strings.
                if any(isinstance(side, (int, float)) and not isinstance(side, bool) for side in (left, right)):
                    equal = number(left) == number(right)
                else:
                    equal = ("" if left is None else str(left)) == ("" if right is None else str(right))
                left = equal if operator == "==" else not equal
            else:
                a, b = number(left), number(right)
                left = {">": a > b, "<": a < b, ">=": a >= b, "<=": a <= b}[operator]
        return left

    def both():
        left = comparison()
        while peek() == "&&":
            take()
            right = comparison()
            left = right if left else left
        return left

    def either():
        left = both()
        while peek() == "||":
            take()
            right = both()
            left = left if left else right
        return left

    value = either()
    if position[0] != len(tokens):
        raise ValueError(f"trailing tokens {tokens[position[0]:]}")
    return value


def github_context(event_name, ref="refs/heads/main", **variables):
    return {
        "github": {"event_name": event_name, "ref": ref, "repository_owner": "manaflow-ai", "run_attempt": "1"},
        "vars": {
            "MACOS_RUNNER_PR": "pool-pr",
            "MACOS_RUNNER_15": "pool-15-paid",
            "CMUX_CI_XCODE_APP_PR": "/Applications/Xcode-pr.app",
            "CMUX_CI_XCODE_APP_MACOS_15": "/Applications/Xcode-15.app",
            **variables,
        },
        "inputs": {"cache_backend": "default"},
        "steps": {},
    }


class Wiring(unittest.TestCase):
    def test_only_the_nightly_seeder_writes_the_seed_and_admission_reads_the_same_key(self):
        seeder = steps("nightly.yml", "refresh-test-compilation-cache")
        record_at, _ = named(seeder, "Record DerivedData seed inputs")
        build_at, _ = named(seeder, "Refresh test compilation cache")
        save_at, save = named(seeder, "Save DerivedData seed")
        self.assertLess(record_at, build_at)
        self.assertLess(build_at, save_at)
        self.assertEqual(save["with"]["backend"], "r2")
        written = save["with"]["key"]
        suffix = "${{ needs.decide.outputs.head_sha }}"
        self.assertEqual(written, "${{ steps.derived-data-seed-key.outputs.scoped }}" + suffix)
        _, scope = named(seeder, "Scope DerivedData seed key")
        self.assertEqual(scope["env"]["FINGERPRINT"], "${{ steps.compilation-cache-key.outputs.fingerprint }}")
        self.assertIn('scope "admission-derived-data-v1-${RUNNER_OS}-${RUNNER_ARCH}-${FINGERPRINT}-"', scope["run"])

        admission = steps("ci-macos.yml", "macos-compile-admission")
        resolve_at, _ = named(admission, "Resolve Swift packages")
        adopt_at, adopt = named(admission, "Adopt the nightly DerivedData seed")
        compile_at, _ = named(admission, "Compile app-host test product")
        forget_at, forget = named(admission, "Forget the adopted-build inode override")
        self.assertLess(resolve_at, adopt_at)
        self.assertLess(adopt_at, compile_at)
        self.assertLess(compile_at, forget_at)
        # Admission passes the unscoped prefix; seed_derived_data.py scopes it.
        self.assertEqual(
            adopt["env"]["SEED_PREFIX"],
            "admission-derived-data-v1-${{ runner.os }}-${{ runner.arch }}-${{ steps.compilation-cache-key.outputs.fingerprint }}-",
        )
        # Adopt writes the override before it can time out, so clear it
        # whenever adopt ran, not only when it reported a hit.
        self.assertIn("steps.seed-derived-data.outcome != 'skipped'", forget["if"])

        for path in (ROOT / ".github/workflows").glob("*.yml"):
            text = path.read_text()
            if "admission-derived-data-" in text and path.name not in {"nightly.yml", "ci-macos.yml", "seed-derived-data.yml", "test-e2e.yml"}:
                self.fail(f"{path.name} names the admission DerivedData seed")
        # E2E builds adopt the same seed but only read it.
        e2e = (ROOT / ".github/workflows/test-e2e.yml").read_text()
        for command in re.findall(r"seed_derived_data\.py (\w+)", e2e):
            self.assertIn(command, {"start", "adopt"})
        self.assertNotIn("secrets.", json.dumps(adopt))

    def test_every_main_push_seeds_incrementally_under_the_key_admission_reads(self):
        workflow = load("seed-derived-data.yml")
        triggers = workflow.get("on", workflow.get(True))
        # Only trusted main code may write a seed pull requests adopt.
        self.assertEqual(set(triggers), {"push", "workflow_dispatch"})
        self.assertEqual(triggers["push"]["branches"], ["main"])
        # cancel-in-progress would starve publishing while merges keep
        # arriving faster than a seed builds; see the comment beside it.
        self.assertIs(workflow["jobs"]["seed"]["concurrency"]["cancel-in-progress"], False)
        # One group per pool: a seed is only useful to admission on that pool.
        self.assertIn(workflow["jobs"]["seed"]["runs-on"].strip("${} "), workflow["jobs"]["seed"]["concurrency"]["group"])

        seeder = steps("seed-derived-data.yml", "seed")
        resolve_at, _ = named(seeder, "Resolve Swift packages")
        adopt_at, adopt = named(seeder, "Adopt the newest seed")
        record_at, _ = named(seeder, "Record seed inputs")
        build_at, _ = named(seeder, "Build")
        save_at, save = named(seeder, "Save seed")
        self.assertLess(resolve_at, adopt_at)
        self.assertLess(adopt_at, record_at)
        self.assertLess(record_at, build_at)
        self.assertLess(build_at, save_at)
        self.assertIs(adopt.get("continue-on-error"), True)
        self.assertEqual(save["with"]["backend"], "r2")
        self.assertEqual(save["with"]["key"], "${{ steps.key.outputs.scoped }}${{ github.sha }}")

        # Same key shape, runner and Xcode as the nightly seeder, or pull
        # requests would never match what this writes.
        _, key = named(seeder, "Compute seed key")
        self.assertIn("admission-derived-data-v1-${RUNNER_OS}-${RUNNER_ARCH}-${fingerprint}-", key["run"])
        nightly = load("nightly.yml")["jobs"]["refresh-test-compilation-cache"]
        job = workflow["jobs"]["seed"]
        self.assertIn(nightly["runs-on"], job["strategy"]["matrix"]["pool"])
        # On the lane's pools the seeder uses the nightly's Xcode.
        context = github_context("push", MACOS_RUNNER_PR="blacksmith-6vcpu-macos-26")
        context["matrix"] = {"pool": "blacksmith-6vcpu-macos-26"}
        self.assertEqual(evaluate(job["env"]["CMUX_CI_XCODE_APP"], context),
                         evaluate(nightly["env"]["CMUX_CI_XCODE_APP"], context))

        # Resolve against the same Swift package cache admission restores, so
        # a layout change invalidates both keys together.
        _, seed_spm = named(seeder, "Cache Swift packages")
        _, admission_spm = named(steps("ci-macos.yml", "macos-compile-admission"), "Cache Swift packages")
        self.assertEqual(seed_spm["with"]["key"], admission_spm["with"]["key"])

    def test_every_pool_admission_compiles_on_gets_a_seed_of_its_width(self):
        """Pull-request admission runs on the 6 or 12 vCPU macOS 26 pool, and a
        seed only serves the width it was built at, so both pools seed."""
        job = load("seed-derived-data.yml")["jobs"]["seed"]
        self.assertEqual(job["runs-on"], "${{ matrix.pool }}")
        self.assertIs(job["strategy"]["fail-fast"], False)
        context = github_context("push", MACOS_RUNNER_PR="blacksmith-6vcpu-macos-26")
        pools = {evaluate(pool, context) for pool in job["strategy"]["matrix"]["pool"]}
        # macOS 15 too: pull requests overflow there, on its own Xcode.
        self.assertEqual(pools, {"blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26",
                                 "blacksmith-6vcpu-macos-15"})
        admission = load("ci-macos.yml")["jobs"]["macos-compile-admission"]["runs-on"]
        self.assertIn(evaluate(admission, github_context("pull_request", ref="refs/pull/1/merge",
                                                         MACOS_RUNNER_PR="blacksmith-6vcpu-macos-26")), pools)
        # Each pool queues on its own, so a slow 6 vCPU seed never holds the
        # 12 vCPU one back, and neither cancels a running seed.
        self.assertIn("matrix.pool", job["concurrency"]["group"])
        self.assertIs(job["concurrency"]["cancel-in-progress"], False)

        # Both writers save under the width they built at.
        seeder = job["steps"]
        _, key = named(seeder, "Compute seed key")
        self.assertIn("seed_derived_data.py scope", key["run"])
        _, save = named(seeder, "Save seed")
        self.assertEqual(save["with"]["key"], "${{ steps.key.outputs.scoped }}${{ github.sha }}")
        # A failed scope call must not save under the bare revision.
        self.assertIn('test -n "$scoped"', key["run"])
        nightly = steps("nightly.yml", "refresh-test-compilation-cache")
        scope_at, scope = named(nightly, "Scope DerivedData seed key")
        save_at, nightly_save = named(nightly, "Save DerivedData seed")
        self.assertLess(scope_at, save_at)
        self.assertIn("seed_derived_data.py scope", scope["run"])
        self.assertTrue(nightly_save["with"]["key"].startswith("${{ steps.derived-data-seed-key.outputs.scoped }}"))

    def test_the_seed_pool_differs_from_admission_only_in_runner_size(self):
        # Seeds used to queue behind pull requests on admission's own pool.
        # They may move to a larger runner of the same image, since neither
        # the seed key nor the product key names the size, but never to
        # another image or Xcode.
        # The 12 vCPU pool comes first: it starts in seconds, and the first
        # entry alone publishes the app-host product.
        runs_on, own, _ = load("seed-derived-data.yml")["jobs"]["seed"]["strategy"]["matrix"]["pool"]
        admission = load("ci-macos.yml")["jobs"]["macos-compile-admission"]["runs-on"]
        larger = "vars.MACOS_RUNNER_PR == 'blacksmith-6vcpu-macos-26' && 'blacksmith-12vcpu-macos-26'"
        self.assertIn(larger, runs_on)
        # Any other pool value is admission's pull-request pool, unchanged.
        fallback = "vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'"
        self.assertTrue(runs_on.rstrip("} ").endswith(f"{larger} || {fallback}"), runs_on)
        self.assertTrue(own.rstrip("} ").endswith(f"'macos-26' || {fallback}"), own)
        self.assertIn(fallback, admission)

    def test_the_macos_15_pool_seeds_with_the_xcode_an_overflowed_run_compiles_with(self):
        import sys as _sys
        _sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import pr_runner_pool

        job = load("seed-derived-data.yml")["jobs"]["seed"]
        *_, overflow = job["strategy"]["matrix"]["pool"]
        context = github_context("push", MACOS_RUNNER_PR="blacksmith-6vcpu-macos-26")
        pool = evaluate(overflow, context)
        self.assertEqual(pool, pr_runner_pool.MACOS_15_RUNNER)
        context["matrix"] = {"pool": pool}
        self.assertEqual(evaluate(job["env"]["CMUX_CI_XCODE_APP"], context), "/Applications/Xcode-15.app")
        self.assertEqual(pr_runner_pool.POOLS[pool], "CMUX_CI_XCODE_APP_MACOS_15")
        # Only the first entry publishes the product, never this one.
        self.assertNotEqual(job["strategy"]["matrix"]["pool"][0], overflow)

    def test_main_push_publishes_the_product_admission_would_compile(self):
        """Pull requests adopt this product in place of compiling, so it has to
        be the admission product: same key, same staging, same packaging, same
        artifact name, published only by a main push, after the seed is saved."""
        workflow = load("seed-derived-data.yml")
        job = workflow["jobs"]["seed"]
        seeder = job["steps"]
        admission = steps("ci-macos.yml", "macos-compile-admission")

        # The consumer names the job and step that must have compiled it.
        self.assertNotIn("name", job)
        build_at, build = named(seeder, "Build")
        self.assertIn("canonical-build", build["run"])
        _, admission_compile = named(admission, "Compile app-host test product")
        self.assertIn("canonical-build", admission_compile["run"])

        save_at, _ = named(seeder, "Save seed")
        key_at, key = named(seeder, "Identify reusable compiled products")
        _, admission_key = named(admission, "Identify reusable compiled products")
        self.assertEqual(key["id"], "product-key")
        self.assertEqual(key["run"], admission_key["run"])
        # The contract fingerprints rustc and cargo, so the key waits for them.
        install_at, _ = named(seeder, "Install compilation dependencies")
        self.assertLess(install_at, key_at)
        self.assertLess(key_at, build_at)

        stage_at, stage = named(seeder, "Stage compiled package frameworks")
        _, admission_stage = named(admission, "Stage compiled package frameworks")
        self.assertEqual(stage["run"], admission_stage["run"])

        package_at, package = named(seeder, "Package compiled app-host test product")
        _, admission_package = named(admission, "Package compiled app-host test product")
        for line in admission_package["run"].splitlines():
            line = line.strip()
            if line.startswith(("(cd ", "python3 ", "COPYFILE_DISABLE=1 ", "echo \"sha256=")):
                self.assertIn(line, package["run"])

        upload_at, upload = named(seeder, "Upload compiled app-host test product")
        _, admission_upload = named(admission, "Upload compiled app-host test product")
        self.assertEqual(upload["uses"], admission_upload["uses"])
        for field in ("name", "path", "compression-level"):
            self.assertEqual(upload["with"][field], admission_upload["with"][field], field)
        self.assertIn("retention-days", upload["with"])

        # Staging and relocation rewrite Build/Products, so they run only once
        # the seed incremental builds read is already saved.
        self.assertLess(build_at, save_at)
        self.assertLess(save_at, stage_at)
        self.assertLess(stage_at, package_at)
        self.assertLess(package_at, upload_at)

        # Only a main push is a trusted producer; a dispatch would upload a
        # product nothing adopts.
        for step in (stage, package, upload):
            self.assertIn("github.event_name == 'push'", step["if"])
            self.assertIn("github.ref == 'refs/heads/main'", step["if"])
            self.assertIs(step.get("continue-on-error"), True)
        self.assertIn("steps.package-products.outcome == 'success'", upload["if"])
        self.assertNotIn("secrets.", json.dumps([stage, package, upload]))

    def test_the_seeder_reads_and_writes_through_the_public_url_admission_reads(self):
        # r2-cache.sh restores through CI_CACHE_R2_PUBLIC_URL and refuses to
        # save without it, so a seeder without it never reads or writes a seed.
        seeder = load("seed-derived-data.yml")
        admission = load("ci-macos.yml")
        self.assertEqual(
            seeder.get("env", {}).get("CI_CACHE_R2_PUBLIC_URL"),
            admission["env"]["CI_CACHE_R2_PUBLIC_URL"],
        )

    def test_the_seed_downloads_while_packages_resolve(self):
        # The download needs only the fingerprint, so it starts before the
        # resolve and the adopt step waits for it instead of downloading
        # serially after the resolve (~40 s of each admission, 2026-09-24).
        admission = steps("ci-macos.yml", "macos-compile-admission")
        key_at, _ = named(admission, "Compute test compilation cache key")
        start_at, start = named(admission, "Start the DerivedData seed download")
        resolve_at, _ = named(admission, "Resolve Swift packages")
        adopt_at, adopt = named(admission, "Adopt the nightly DerivedData seed")
        self.assertLess(key_at, start_at)
        self.assertLess(start_at, resolve_at)
        self.assertLess(resolve_at, adopt_at)
        self.assertEqual(start["if"], adopt["if"])
        self.assertEqual(start["env"], adopt["env"])
        self.assertIs(start.get("continue-on-error"), True)
        self.assertIn("seed_derived_data.py start", start["run"])
        self.assertIn("seed_derived_data.py adopt", adopt["run"])
        # The adopt step's own deadline must fire before the step timeout, or
        # a timed-out step leaves the detached download pulling a seed through
        # the compile.
        self.assertLess(seed.FETCH_WAIT_SECONDS, adopt["timeout-minutes"] * 60 - 30)
        # Like adoption, starting the download never decides what the product
        # is, so it must not move the product recipe (and every edit to it
        # would otherwise invalidate every reusable product).
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
        import product_input_identity
        self.assertIn("Start the DerivedData seed download", product_input_identity.NON_PRODUCT_RECIPE_STEPS)

    def test_adoption_is_optional_and_limited_to_pull_requests_and_main_dispatch(self):
        admission = steps("ci-macos.yml", "macos-compile-admission")
        _, adopt = named(admission, "Adopt the nightly DerivedData seed")
        self.assertIs(adopt.get("continue-on-error"), True)
        self.assertIn("github.event_name == 'pull_request'", adopt["if"])
        # An unset repository variable is null, and Actions compares null with
        # '0' as the numbers 0 and 0. A bare `vars.X != '0'` is therefore false
        # while X is unset, which turned adoption off everywhere. Unset has to
        # mean on, so the kill switch gets a non-zero default first.
        self.assertIn("(vars.CI_ADMISSION_SEED_DERIVED_DATA || '1') != '0'", adopt["if"])
        self.assertIn("timeout-minutes", adopt)

    def test_main_full_suite_admission_adopts_the_seed_for_its_own_commit(self):
        # ci-main-full-suite.yml dispatches ci.yml on main, and its admission
        # compiled main's HEAD cold although seed-derived-data.yml had just
        # built that commit or its parent. It must start from the seed.
        _, adopt = named(steps("ci-macos.yml", "macos-compile-admission"), "Adopt the nightly DerivedData seed")
        for overflow in ("", "1"):
            main_dispatch = github_context("workflow_dispatch", CI_PAID_MACOS_OVERFLOW=overflow)
            self.assertTrue(evaluate(adopt["if"], main_dispatch))
        # A dispatch on another branch and a merge group still build clean.
        self.assertFalse(evaluate(adopt["if"], github_context("workflow_dispatch", ref="refs/heads/topic")))
        self.assertFalse(evaluate(adopt["if"], github_context("merge_group", ref="refs/heads/gh-readonly-queue/main/x")))
        self.assertTrue(evaluate(adopt["if"], github_context("pull_request", ref="refs/pull/1/merge")))
        self.assertFalse(evaluate(adopt["if"], github_context("workflow_dispatch", CI_ADMISSION_SEED_DERIVED_DATA="0")))
        # The seed search starts at the main commit a pull request merges
        # onto, or at the dispatched commit itself, never its parent: that
        # commit's own seed may already exist.
        self.assertIn('"$SEED_PREFIX" "$MERGED_ONTO"', adopt["run"])
        onto = adopt["env"]["MERGED_ONTO"]
        dispatch = github_context("workflow_dispatch")
        dispatch["github"]["sha"] = "head"
        dispatch["inputs"]["source_parent1"] = "parent"
        self.assertEqual(evaluate(onto, dispatch), "head")
        pull = github_context("pull_request", ref="refs/pull/1/merge")
        pull["github"].update(sha="merge", event={"pull_request": {"base": {"sha": "base"}}})
        self.assertEqual(evaluate(onto, pull), "base")
        pull["inputs"]["source_parent1"] = "parent"
        self.assertEqual(evaluate(onto, pull), "parent")

    def test_main_full_suite_admission_compiles_on_the_seed_pool_and_xcode(self):
        # The seed key carries the Xcode and the seed was built on its pool, so
        # admission can only adopt it where the seeder compiled.
        admission = load("ci-macos.yml")["jobs"]["macos-compile-admission"]
        seeder = load("seed-derived-data.yml")["jobs"]["seed"]
        for overflow in ("", "1"):
            for unset in ((), ("MACOS_RUNNER_PR", "CMUX_CI_XCODE_APP_PR")):
                context = github_context("workflow_dispatch", CI_PAID_MACOS_OVERFLOW=overflow)
                for name in unset:
                    context["vars"].pop(name)
                pools = [evaluate(pool, context) for pool in seeder["strategy"]["matrix"]["pool"]]
                self.assertIn(evaluate(admission["runs-on"], context), pools)
                self.assertEqual(
                    evaluate(admission["env"]["CMUX_CI_XCODE_APP"], context),
                    evaluate(seeder["env"]["CMUX_CI_XCODE_APP"], context),
                )
        # Pull requests already compile there; other events keep their lane.
        pull_request = github_context("pull_request", ref="refs/pull/1/merge")
        self.assertEqual(evaluate(admission["runs-on"], pull_request), "pool-pr")
        merge_group = github_context("merge_group", ref="refs/heads/gh-readonly-queue/main/x", CI_PAID_MACOS_OVERFLOW="1")
        self.assertEqual(evaluate(admission["runs-on"], merge_group), "pool-15-paid")
        self.assertEqual(evaluate(admission["env"]["CMUX_CI_XCODE_APP"], merge_group), "/Applications/Xcode-15.app")
        branch_dispatch = github_context("workflow_dispatch", ref="refs/heads/topic")
        self.assertEqual(evaluate(admission["runs-on"], branch_dispatch), "blacksmith-6vcpu-macos-15")

    def test_fork_pull_request_admission_stays_on_blacksmith(self):
        # MACOS_RUNNER_PR (pool-pr here) may name an owned Mac. A fork pull
        # request keeps the pool picker's choice only when it is Blacksmith,
        # and never reads the pull-request lane's Xcode pin.
        admission = load("ci-macos.yml")["jobs"]["macos-compile-admission"]
        for head, picked, runner in (
            ("someone/cmux", "", "blacksmith-6vcpu-macos-15"),
            ("someone/cmux", "blacksmith-12vcpu-macos-26", "blacksmith-12vcpu-macos-26"),
            ("someone/cmux", "owned-mac", "blacksmith-6vcpu-macos-15"),
            # A deleted head repository reads as null and counts as a fork.
            (None, "", "blacksmith-6vcpu-macos-15"),
            ("manaflow-ai/cmux", "", "pool-pr"),
        ):
            context = github_context("pull_request", ref="refs/pull/1/merge")
            context["github"].update(repository="manaflow-ai/cmux",
                                     event={"pull_request": {"head": {"repo": {"full_name": head}}}})
            context["inputs"]["pr_runner"] = picked
            with self.subTest(head=head, picked=picked):
                self.assertEqual(evaluate(admission["runs-on"], context), runner)
                self.assertEqual(evaluate(admission["env"]["CMUX_PRODUCT_RUNNER"], context), runner)
                self.assertEqual(
                    evaluate(admission["env"]["CMUX_CI_XCODE_APP"], context),
                    "/Applications/Xcode-pr.app" if head == "manaflow-ai/cmux" else "/Applications/Xcode-15.app",
                )

    def test_a_rerun_of_an_owned_pool_run_takes_the_retry_runner(self):
        # pr_runner_pool.py names pr_retry_runner only for an owned-pool pick; a
        # re-run of failed jobs (attempt 2) reuses attempt 1's inputs.
        admission = load("ci-macos.yml")["jobs"]["macos-compile-admission"]
        # Attempt 1 takes the owned pool only when the picker placed admission
        # there (pr_owned_jobs); otherwise the retry runner.
        for attempt, retry, owned_jobs, runner in (
            ("1", "blacksmith-12vcpu-macos-26", " admission cli-pipe ", "glaeda-std-xcode-26.6"),
            ("1", "blacksmith-12vcpu-macos-26", " cli-pipe ", "blacksmith-12vcpu-macos-26"),
            ("1", "blacksmith-12vcpu-macos-26", "", "blacksmith-12vcpu-macos-26"),
            ("2", "blacksmith-12vcpu-macos-26", " admission ", "blacksmith-12vcpu-macos-26"),
            ("2", "", "", "glaeda-std-xcode-26.6"),
        ):
            context = github_context("pull_request", ref="refs/pull/1/merge")
            context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt,
                                     event={"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}}}})
            context["inputs"].update(pr_runner="glaeda-std-xcode-26.6", pr_retry_runner=retry,
                                     pr_owned_jobs=owned_jobs)
            with self.subTest(attempt=attempt, retry=retry, owned_jobs=owned_jobs):
                self.assertEqual(evaluate(admission["runs-on"], context), runner)
                self.assertEqual(evaluate(admission["env"]["CMUX_PRODUCT_RUNNER"], context), runner)

    def test_only_the_rescue_retries_a_refused_owned_job_on_the_fleet(self):
        # owned_pool_rescue.py re-runs a refused job's failed jobs with
        # github.token, so attempt 2 is triggered by github-actions[bot] and
        # takes the owned label once more. A person's "Re-run failed jobs" is
        # also attempt 2 with the same outputs, but nothing watches it, so it
        # takes the Blacksmith retry runner.
        admission = load("ci-macos.yml")["jobs"]["macos-compile-admission"]
        for actor, runner in (("github-actions[bot]", "glaeda-std-xcode-26.6"),
                              ("someone", "blacksmith-12vcpu-macos-26")):
            context = github_context("pull_request", ref="refs/pull/1/merge")
            context["github"].update(repository="manaflow-ai/cmux", run_attempt="2", triggering_actor=actor,
                                     event={"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}}}})
            context["inputs"].update(pr_runner="glaeda-std-xcode-26.6", pr_retry_runner="blacksmith-12vcpu-macos-26",
                                     pr_refused_retry_runner="glaeda-std-xcode-26.6", pr_owned_jobs=" admission ")
            with self.subTest(actor=actor):
                self.assertEqual(evaluate(admission["runs-on"], context), runner)
                self.assertEqual(evaluate(admission["env"]["CMUX_PRODUCT_RUNNER"], context), runner)

    def test_full_suite_shards_take_the_shard_runner_on_admissions_xcode(self):
        shards = load("ci-macos.yml")["jobs"]["app-host-unit-tests"]
        for retry, owned, shard, runner in (
            ("", "", "blacksmith-6vcpu-macos-26", "blacksmith-6vcpu-macos-26"),  # spread off 12vcpu
            ("", "", "", "blacksmith-12vcpu-macos-26"),                          # stay with admission
            # An owned run's shards not placed there take the retry runner.
            ("blacksmith-12vcpu-macos-26", " admission ", "", "blacksmith-12vcpu-macos-26"),
        ):
            context = github_context("pull_request", ref="refs/pull/1/merge")
            context["github"].update(repository="manaflow-ai/cmux", run_attempt="1",
                                     event={"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}}}})
            context["inputs"].update(pr_retry_runner=retry, pr_owned_jobs=owned, pr_shard_runner=shard)
            context["matrix"] = {"shard": 3}
            context["needs"] = {"macos-compile-admission": {"outputs": {"runner": "blacksmith-12vcpu-macos-26"}}}
            with self.subTest(retry=retry, shard=shard):
                self.assertEqual(evaluate(shards["runs-on"], context), runner)

    def test_the_expression_evaluator_follows_actions_semantics(self):
        context = {"vars": {"A": "a", "EMPTY": ""}}
        self.assertEqual(evaluate("${{ vars.A && 'x' || 'y' }}", context), "x")
        self.assertEqual(evaluate("${{ vars.EMPTY && 'x' || 'y' }}", context), "y")
        self.assertEqual(evaluate("${{ vars.MISSING || vars.A }}", context), "a")
        self.assertIs(evaluate("${{ !(vars.A == 'a') }}", context), False)
        self.assertIs(evaluate("${{ (vars.MISSING || '1') != '0' }}", context), True)
        self.assertIs(evaluate("${{ vars.A != 'b' && vars.A == 'a' }}", context), True)
        self.assertIs(evaluate("${{ startsWith(vars.A, 'A') }}", context), True)
        numbers = {"github": {"run_attempt": "2"}, "vars": {"A": "a"}}
        self.assertIs(evaluate("${{ github.run_attempt > 1 }}", numbers), True)
        self.assertIs(evaluate("${{ github.run_attempt > 2 }}", numbers), False)
        self.assertIs(evaluate("${{ vars.MISSING > 0 }}", numbers), False)
        self.assertIs(evaluate("${{ vars.A > 0 || vars.A < 1 }}", numbers), False)
        self.assertIs(evaluate("${{ startsWith(vars.MISSING, 'a') }}", context), False)

    def test_no_workflow_compares_a_bare_variable_with_zero(self):
        bare = re.compile(r"vars\.[A-Z0-9_]+\s*[!=]=\s*'0'")
        offenders = [
            f"{path.name}:{number}"
            for path in sorted((ROOT / ".github/workflows").glob("*.yml"))
            for number, line in enumerate(path.read_text().splitlines(), 1)
            if bare.search(line)
        ]
        self.assertEqual(offenders, [], "an unset variable is null, which equals '0'; give it a default first")


if __name__ == "__main__":
    unittest.main()
