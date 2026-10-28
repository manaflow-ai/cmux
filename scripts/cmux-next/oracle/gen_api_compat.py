#!/usr/bin/env python3
"""Generate the api-compat suite: one oracle case per translator vector of the api-compat fixture file.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite api-compat) and task 211. Stdlib only,
Python 3.9+, safe under `python3 -I`. `oracle.py gen --suite api-compat` runs it with `--out <corpus>/api-compat`.

Chrome reference (chromium/src): mojo/public/interfaces/bindings/tests/data/validation/ keeps one set of message
vectors that every bindings runner reads. Here the vectors are the `vectors` of
cmux-tui/spec/api-compat-fixtures.json: a rule chain (an api-compat schema), one message as written, and the
output or refusal it must give. `cargo test -p cmux-api-compat` replays them in process against the expected
result. Each case here runs one in the build under test: a read-only `cli` step whose stdin is the whole vector,
expected result included, sent to the cmux binary's `__oracle-api-compat` mode (debug and `--features oracle`
builds; cmux-tui/crates/cmux-tui/src/private_mode.rs). The mode checks the result there: a match prints
`{"output": ...}` or `{"refused": "<kind>"}` and exits 0, anything else prints the typed error
`api_compat.mismatch` and exits 1, so the step's `ok` outcome fails in the arm whose translator is wrong.

Only the cli product runs these cases: its driver (p15-oracle-048) runs the bare oracle-built binary with the
case's argv. The other products put global flags before argv or ship a binary without the mode, so
tests/oracle/NeverFix.d/api-compat.txt skips the suite there. Until 048 lands, `--replay BINARY` runs every
case's step against a built cmux directly.

The generator owns the suite directory: every `*.json` in it is a case it wrote, and a vector that leaves the
fixture file takes its case with it. Output is byte-stable: a second run writes nothing.

Usage:
  gen_api_compat.py [--out DIR]          write the cases into DIR (default: the corpus suite directory)
  gen_api_compat.py [--out DIR] --check  exit 1 when DIR differs from a fresh generation
  gen_api_compat.py --selftest           offline tests against the checked-in fixture file
  gen_api_compat.py --replay BINARY      run every checked-in case's step against BINARY (a debug cmux)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
FIXTURES = REPO / "cmux-tui" / "spec" / "api-compat-fixtures.json"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "api-compat"
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
SUITE = "api-compat"
GENERATOR = "scripts/cmux-next/oracle/gen_api_compat.py"
FIXTURES_REL = "cmux-tui/spec/api-compat-fixtures.json"
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
MODE = "__oracle-api-compat"
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
TRANSLATION_KEYS = ("schema", "message", "from", "to", "input")
VECTOR_KEYS = ("id", "title", "translation", "expect")
EXPECT_KINDS = ("bytes", "json", "error")
MISMATCH = "api_compat.mismatch"


class GenError(Exception):
    """The fixture file cannot be turned into cases."""


def load_vectors(path: Path = FIXTURES) -> List[Mapping[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise GenError(f"{path}: {error}") from error
    vectors = data.get("vectors") if isinstance(data, dict) else None
    if not isinstance(vectors, list):
        raise GenError(f"{path}: no `vectors` array")
    seen = set()
    for index, vector in enumerate(vectors):
        where = f"{path.name} vectors[{index}]"
        if not isinstance(vector, dict):
            raise GenError(f"{where}: not an object")
        vid = vector.get("id")
        if not isinstance(vid, str) or not SLUG.match(vid):
            raise GenError(f"{where}: id {vid!r} is not a case slug [a-z0-9][a-z0-9-]{{0,63}}")
        if vid in seen:
            raise GenError(f"{where}: id {vid} repeats")
        seen.add(vid)
        title = vector.get("title")
        if not isinstance(title, str) or not title or len(title) > 200:
            raise GenError(f"{where} ({vid}): title must be 1 to 200 characters")
        translation = vector.get("translation")
        if not isinstance(translation, dict) or sorted(translation) != sorted(TRANSLATION_KEYS):
            raise GenError(f"{where} ({vid}): translation must have exactly {', '.join(TRANSLATION_KEYS)}")
        if not isinstance(translation["input"], str):
            raise GenError(f"{where} ({vid}): translation.input must be the message text")
        expect = vector.get("expect")
        if not isinstance(expect, dict) or len(expect) != 1 or next(iter(expect)) not in EXPECT_KINDS:
            raise GenError(f"{where} ({vid}): expect must be exactly one of {', '.join(EXPECT_KINDS)}")
        if sorted(vector) != sorted(VECTOR_KEYS):
            raise GenError(f"{where} ({vid}): a vector has exactly {', '.join(VECTOR_KEYS)}")
    return vectors


def stdin_of(vector: Mapping[str, Any]) -> str:
    """The `__oracle-api-compat` request: the whole vector, expected result included, as canonical JSON (the
    input stays a string, so its bytes are exact)."""
    return json.dumps(vector, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def case_doc(vector: Mapping[str, Any]) -> Dict[str, Any]:
    vid = vector["id"]
    translation = vector["translation"]
    return {
        "$schema": SCHEMA_REF,
        "corpusVersion": 1,
        "id": vid,
        "suite": SUITE,
        "title": vector["title"],
        "surface": "cmux-tui",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": {"seed": f"{SUITE}.{vid}", "network": "offline", "clock": "fixed"},
        "preconditions": [f"a cmux binary with debug assertions or --features oracle (the {MODE} mode)"],
        "requires": ["resource_api"],
        "platforms": ["linux", "mac"],
        "steps": [
            {
                "id": "translate",
                "op": "cli",
                "readOnly": True,
                "args": {"argv": [MODE], "stdin": stdin_of(vector)},
                "expect": {"outcome": "ok"},
                "note": f"{translation['message']} from revision {translation['from']} to {translation['to']}; "
                        f"a result other than the vector's expect is {MISMATCH} (exit 1)",
            }
        ],
        "invariants": [
            f"generated by {GENERATOR} from vector {vid} of {FIXTURES_REL}",
            f"the build under test checks its result against the vector's expect and exits 1 with {MISMATCH} "
            "on a difference; cargo test -p cmux-api-compat checks the same vector in process",
        ],
        "teardown": ["nothing to undo: the step reads stdin and writes stdout"],
    }


def generate(vectors: Sequence[Mapping[str, Any]]) -> Dict[str, Any]:
    return {f"{vector['id']}.json": case_doc(vector) for vector in vectors}


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def owned_files(out: Path) -> List[str]:
    return sorted(path.name for path in out.glob("*.json")) if out.is_dir() else []


def drift(out: Path, files: Mapping[str, Any]) -> List[str]:
    problems = []
    for name, value in sorted(files.items()):
        path = out / name
        if not path.is_file():
            problems.append(f"{name}: missing")
        elif path.read_text(encoding="utf-8") != render(value):
            problems.append(f"{name}: differs from a fresh generation")
    problems.extend(f"{name}: no vector in {FIXTURES_REL} has this id" for name in owned_files(out) if name not in files)
    return problems


def write(out: Path, files: Mapping[str, Any]) -> Tuple[int, int]:
    out.mkdir(parents=True, exist_ok=True)
    written = 0
    for name, value in sorted(files.items()):
        path = out / name
        text = render(value)
        if not path.is_file() or path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8")
            written += 1
    removed = 0
    for name in owned_files(out):
        if name not in files:
            (out / name).unlink()
            removed += 1
    return written, removed


# --------------------------------------------------------------------------------------------- replay


def wrong_expect(expect: Mapping[str, Any]) -> Dict[str, Any]:
    """An expectation the vector's real result never meets: a refusal for an output, an output for a refusal."""
    return {"bytes": ""} if "error" in expect else {"error": "bad_pointer"}


def run_step(binary: Path, stdin: str, home: Path) -> Tuple[int, Any]:
    """The case's step as the cli driver runs it: the bare binary, the case's argv, its stdin."""
    done = subprocess.run([str(binary), MODE], input=stdin, capture_output=True, text=True, timeout=60,
                          cwd=home, env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home)})
    try:
        reply = json.loads(done.stdout) if done.stdout.strip() else None
    except ValueError:
        reply = done.stdout
    return done.returncode, reply


def replay(binary: Path, out: Path = DEFAULT_OUT) -> List[str]:
    """Every case's step against `binary`: the vector as written must pass (exit 0, a typed result), and the
    same vector with a wrong expect must fail with MISMATCH (exit 1), so a build that skips the check is caught."""
    problems: List[str] = []
    names = owned_files(out)
    if not names:
        return [f"{out}: no cases"]
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        for name in names:
            step = json.loads((out / name).read_text(encoding="utf-8"))["steps"][0]
            if step["args"]["argv"] != [MODE]:
                problems.append(f"{name}: argv {step['args']['argv']} is not [{MODE}]")
                continue
            code, reply = run_step(binary, step["args"]["stdin"], home)
            if code != 0 or not (isinstance(reply, dict) and len(reply) == 1 and set(reply) <= {"output", "refused"}):
                problems.append(f"{name}: exit {code}, reply {json.dumps(reply)[:300]}")
            vector = json.loads(step["args"]["stdin"])
            vector["expect"] = wrong_expect(vector["expect"])
            code, reply = run_step(binary, stdin_of(vector), home)
            error = reply.get("error") if isinstance(reply, dict) else None
            if code != 1 or not isinstance(error, dict) or error.get("code") != MISMATCH:
                problems.append(f"{name}: a wrong expect gave exit {code}, reply {json.dumps(reply)[:300]}")
    return problems


# --------------------------------------------------------------------------------------------- self test


class GenApiCompatSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.vectors = load_vectors()
        cls.files = generate(cls.vectors)

    def test_one_case_per_vector(self) -> None:
        self.assertGreaterEqual(len(self.vectors), 20)
        self.assertEqual(sorted(self.files), sorted(f"{v['id']}.json" for v in self.vectors))
        for vector in self.vectors:
            step = self.files[f"{vector['id']}.json"]["steps"][0]
            self.assertEqual(step["args"]["argv"], [MODE])
            self.assertEqual(json.loads(step["args"]["stdin"]), vector, vector["id"])

    def test_every_case_pins_the_vector_expect(self) -> None:
        for vector in self.vectors:
            step = self.files[f"{vector['id']}.json"]["steps"][0]
            sent = json.loads(step["args"]["stdin"])
            self.assertEqual(sent["expect"], vector["expect"], vector["id"])
            self.assertEqual(sent["translation"], vector["translation"], vector["id"])
            self.assertEqual(step["expect"], {"outcome": "ok"}, vector["id"])
            self.assertNotEqual(wrong_expect(vector["expect"]), vector["expect"], vector["id"])

    def test_a_mismatch_reply_fails_the_case(self) -> None:
        # The mode's mismatch line, read the way the case-v1 cli op reads a non-zero exit (driver_app.op_cli).
        if str(HERE) not in sys.path:
            sys.path.insert(0, str(HERE))
        driver = __import__("driver_app")
        reply = {"error": {"code": MISMATCH, "message": "vector v: got {\"output\":\"{}\"}, ..."}}
        code = driver.typed_error("cli", reply["error"])
        self.assertEqual(code, MISMATCH)
        step = self.files[sorted(self.files)[0]]["steps"][0]
        checker = driver.CaseRun.check_expect
        with self.assertRaises(driver.CaseError) as raised:
            checker(None, step, ("error", code))
        self.assertEqual(raised.exception.status, "Failure")
        checker(None, step, ("ok", {"exit": 0, "stdout": {"output": "{}"}}))

    def test_only_the_cli_product_runs_the_suite(self) -> None:
        if str(HERE) not in sys.path:
            sys.path.insert(0, str(HERE))
        expectations = __import__("expectations")
        store = expectations.Expectations.load_root()
        self.assertEqual([d for d in expectations.lint(store) if Path(str(d.file)).name == f"{SUITE}.txt"], [])
        case = sorted(self.files)[0][: -len(".json")]
        for product in expectations.TAG_GROUPS["product"]:
            config = expectations.RunConfig(platform="linux", arm="new", product=product, build="debug")
            self.assertEqual(store.should_run(SUITE, case, config), product == "cli", product)

    def test_replay_catches_a_build_that_does_not_check(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "cases"
            write(out, dict(sorted(self.files.items())[:2]))
            fake = Path(tmp) / "cmux"
            fake.write_text(f"#!{sys.executable} -I\nimport sys\nsys.stdin.read()\nprint('{{\"output\": \"x\"}}')\n",
                            encoding="utf-8")
            fake.chmod(0o755)
            problems = replay(fake, out)
            self.assertEqual(len(problems), 2, problems)
            self.assertTrue(all("a wrong expect gave exit 0" in p for p in problems), problems)
            self.assertEqual(replay(fake, Path(tmp) / "empty"), [f"{Path(tmp) / 'empty'}: no cases"])

    def test_cases_pass_the_case_schema(self) -> None:
        if str(HERE) not in sys.path:
            sys.path.insert(0, str(HERE))
        normalize = __import__("normalize")
        checks = __import__("case_checks")
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        rules = checks.Rules(schema)
        for name, case in sorted(self.files.items()):
            self.assertEqual(normalize.validate(case, schema), [], name)
            self.assertEqual(checks.check_case(case, rules), [], name)

    def test_the_checked_in_corpus_is_up_to_date(self) -> None:
        self.assertEqual(drift(DEFAULT_OUT, self.files), [], f"run python3 {GENERATOR}")

    def test_regeneration_is_stable_and_owns_the_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            self.assertEqual(write(out, self.files), (len(self.files), 0))
            self.assertEqual(write(out, generate(load_vectors())), (0, 0))
            self.assertEqual(drift(out, self.files), [])
            first = sorted(self.files)[0]
            (out / first).write_text("{}\n", encoding="utf-8")
            (out / "gone-vector.json").write_text("{}\n", encoding="utf-8")
            self.assertEqual(drift(out, self.files), [f"{first}: differs from a fresh generation",
                                                      f"gone-vector.json: no vector in {FIXTURES_REL} has this id"])
            self.assertEqual(write(out, self.files), (1, 1))
            self.assertEqual(drift(out, self.files), [])

    def test_bad_fixture_files_are_refused(self) -> None:
        good = dict(self.vectors[0])
        bad_sets = {
            "repeats": [good, good],
            "not a case slug": [{**good, "id": "Upper"}],
            "title": [{**good, "title": ""}],
            "translation must have": [{**good, "translation": {**good["translation"], "extra": 1}}],
            "message text": [{**good, "translation": {**good["translation"], "input": {"a": 1}}}],
            "expect must be": [{**good, "expect": {"bytes": "{}", "error": "malformed"}}],
            "a vector has exactly": [{**good, "extra": 1}],
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixtures.json"
            for needle, vectors in bad_sets.items():
                path.write_text(json.dumps({"cases": [], "vectors": vectors}), encoding="utf-8")
                with self.assertRaisesRegex(GenError, needle):
                    load_vectors(path)
            path.write_text(json.dumps({"cases": []}), encoding="utf-8")
            with self.assertRaisesRegex(GenError, "no `vectors` array"):
                load_vectors(path)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the suite directory (default: the corpus)")
    parser.add_argument("--fixtures", type=Path, default=FIXTURES)
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    parser.add_argument("--selftest", action="store_true", help="run the offline self tests")
    parser.add_argument("--replay", type=Path, metavar="BINARY",
                        help="run every case in --out against BINARY, a debug or --features oracle cmux")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GenApiCompatSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.replay is not None:
        problems = replay(args.replay, args.out)
        for problem in problems:
            print(f"gen_api_compat: {problem}", file=sys.stderr)
        print(f"gen_api_compat: replay {len(owned_files(args.out))} cases, {len(problems)} problems")
        return 1 if problems else 0
    try:
        files = generate(load_vectors(args.fixtures))
    except GenError as error:
        print(f"gen_api_compat: {error}", file=sys.stderr)
        return 2
    if args.check:
        problems = drift(args.out, files)
        for problem in problems:
            print(f"gen_api_compat: {problem}", file=sys.stderr)
        print(f"gen_api_compat: {len(files)} cases, {'stale' if problems else 'up to date'}")
        return 1 if problems else 0
    written, removed = write(args.out, files)
    print(f"gen_api_compat: {len(files)} cases, {written} files written, {removed} removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
