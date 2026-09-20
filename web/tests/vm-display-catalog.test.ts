import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import path from "node:path";

test("guest display catalog allocates independent, replayable resources", () => {
  const root = path.resolve(import.meta.dirname, "../..");
  const result = spawnSync("python3", ["-B", "-m", "unittest", "tests/test_cloud_display_catalog.py", "-v"], {
    cwd: root,
    encoding: "utf8",
    timeout: 30_000,
  });
  expect({ status: result.status, error: result.error?.message, output: result.stderr }).toEqual({
    status: 0,
    error: undefined,
    output: expect.stringContaining("OK"),
  });
});
