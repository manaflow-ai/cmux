"""scripts/cmux-next/check-build-spaces.py: every Durable Object binding is classified, and nothing reaches an object
outside its build space (backend/apps/api/src/build-space.ts)."""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/cmux-next/check-build-spaces.py"
WRANGLER = """{ "durable_objects": { "bindings": [
  { "name": "USER_DO", "class_name": "UserDO" },
  { "name": "TEAM_DO", "class_name": "TeamDO" }%s
] } }
"""
SPACES = """export const PER_BUILD_BINDINGS = [%s] as const
export const ACCOUNT_WIDE_BINDINGS = [%s] as const
"""
GOOD_DO = """import { envForObject } from "./build-space.ts"
export class UserDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, raw: RawEnv) { super(ctx, envForObject(ctx, raw)) }
}
"""


def run(files: dict[str, str]) -> tuple[int, str]:
    with tempfile.TemporaryDirectory() as tmp:
        for rel, text in files.items():
            path = Path(tmp) / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        done = subprocess.run([sys.executable, "-I", str(CHECK), tmp], capture_output=True, text=True)
        return done.returncode, done.stdout


def tree(extra_binding: str = "", per: str = '"USER_DO"', shared: str = '"TEAM_DO"', **src: str) -> dict[str, str]:
    return {"backend/apps/api/wrangler.jsonc": WRANGLER % extra_binding, "backend/apps/api/src/build-space.ts": SPACES % (per, shared),
            **{f"backend/apps/api/src/{k.replace('_', '-')}.ts": v for k, v in src.items()}}


class CheckBuildSpacesTests(unittest.TestCase):
    def test_a_classified_tree_passes(self):
        self.assertEqual(run(tree(user_do=GOOD_DO)), (0, ""))

    def test_an_unlisted_binding_fails(self):
        code, out = run(tree(',\n  { "name": "NEW_DO", "class_name": "NewDO" }'))
        self.assertEqual(code, 1)
        self.assertIn("NEW_DO is in neither PER_BUILD_BINDINGS nor ACCOUNT_WIDE_BINDINGS", out)
        self.assertIn("wrangler.jsonc:4:", out)

    def test_a_binding_in_both_lists_fails(self):
        code, out = run(tree(per='"USER_DO", "TEAM_DO"'))
        self.assertEqual(code, 1)
        self.assertIn("TEAM_DO is in both", out)

    def test_an_object_without_its_space_fails(self):
        code, out = run(tree(user_do="export class UserDO extends DurableObject<Env> {}\n"))
        self.assertEqual(code, 1)
        self.assertIn("user-do.ts:1: a Durable Object class", out)

    def test_an_entry_point_on_the_spaced_env_fails(self):
        code, out = run(tree(gate="export class Gate extends WorkerEntrypoint<Env> {}\n"))
        self.assertEqual(code, 1)
        self.assertIn("gate.ts:1: an entry point", out)

    def test_a_raw_env_reaching_an_object_fails(self):
        code, out = run(tree(route="const stub = raw.USER_DO.get(raw.USER_DO.idFromName(user))\n"))
        self.assertEqual(code, 1)
        self.assertEqual(out.count("route.ts:1: a raw env"), 2)


if __name__ == "__main__":
    unittest.main()
