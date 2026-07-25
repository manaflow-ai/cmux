import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const webRoot = fileURLToPath(new URL("..", import.meta.url));

test("shared web test runner isolates module mocks across files", () => {
  const result = spawnSync(
    process.execPath,
    [
      "run",
      "test",
      "--",
      "--randomize",
      "--seed=1",
      "tests/feedback-route.test.ts",
      "tests/founders-welcome-route.test.ts",
    ],
    {
      cwd: webRoot,
      encoding: "utf8",
    },
  );
  const output = [result.stdout, result.stderr].join("\n");

  if (result.status !== 0) {
    throw new Error(`shared web test runner leaked module state:\n${output}`);
  }
  expect(output).toContain("12 pass");
  expect(output).toContain("0 fail");
});
