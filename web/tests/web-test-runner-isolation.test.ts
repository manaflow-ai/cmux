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
      timeout: 30_000,
      killSignal: "SIGKILL",
    },
  );
  const output = [result.stdout, result.stderr].join("\n");

  if (result.error) {
    throw new Error(
      `shared web test runner did not finish: ${result.error.message}\n${output}`,
    );
  }
  if (result.status !== 0) {
    throw new Error(`shared web test runner leaked module state:\n${output}`);
  }
  expect(output).toContain("tests/feedback-route.test.ts:");
  expect(output).toContain("tests/founders-welcome-route.test.ts:");
  expect(output).toContain("0 fail");
});
