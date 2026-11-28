import { describe, expect, test } from "bun:test";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../../../../../", import.meta.url));

describe("icon pack", () => {
  // The pack, the native catalog and the Swift names are generated from design/icons/source.
  test("generated outputs match the sources", () => {
    const run = Bun.spawnSync(["python3", "scripts/icons/build_pack.py", "--check"], { cwd: repoRoot });
    expect(run.stderr.toString() + run.stdout.toString()).toBe("");
    expect(run.exitCode).toBe(0);
  });
});
