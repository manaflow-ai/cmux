import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = fileURLToPath(new URL("..", import.meta.url));
const runnerPath = fileURLToPath(
  new URL("../scripts/run-tests.sh", import.meta.url),
);
const fixtureTestSource = `
import { test } from "bun:test";
test("fixture runs", () => {});
`;

test("shared web test runner isolates module mocks across files", () => {
  const result = runChild(
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
    webRoot,
  );

  if (result.status !== 0) {
    throw new Error(
      `shared web test runner leaked module state:\n${result.output}`,
    );
  }
  expect(result.output).toContain("tests/feedback-route.test.ts:");
  expect(result.output).toContain("tests/founders-welcome-route.test.ts:");
  expect(result.output).toContain("0 fail");
});

test("shared web test runner preserves recursive default discovery", () => {
  const fixtureRoot = createRunnerFixture();
  try {
    mkdirSync(join(fixtureRoot, "tests", "nested"), { recursive: true });
    writeFileSync(
      join(fixtureRoot, "tests", "top-level.test.ts"),
      fixtureTestSource,
    );
    writeFileSync(
      join(fixtureRoot, "tests", "nested", "nested.test.ts"),
      fixtureTestSource,
    );

    const result = runChild(
      "/bin/bash",
      ["scripts/run-tests.sh"],
      fixtureRoot,
    );
    if (result.status !== 0) {
      throw new Error(
        `shared web test runner skipped recursive discovery:\n${result.output}`,
      );
    }
    expect(result.output).toContain("tests/top-level.test.ts:");
    expect(result.output).toContain("tests/nested/nested.test.ts:");
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

test("shared web test runner fails when default discovery finds no tests", () => {
  const fixtureRoot = createRunnerFixture();
  try {
    mkdirSync(join(fixtureRoot, "tests"));
    const result = runChild(
      "/bin/bash",
      ["scripts/run-tests.sh"],
      fixtureRoot,
    );
    expect(result.status).not.toBe(0);
    expect(result.output).toContain(
      "cmux web test runner found no test files",
    );
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

function createRunnerFixture(): string {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "cmux-web-test-runner-"));
  mkdirSync(join(fixtureRoot, "scripts"));
  copyFileSync(runnerPath, join(fixtureRoot, "scripts", "run-tests.sh"));
  return fixtureRoot;
}

function runChild(
  command: string,
  args: string[],
  cwd: string,
): { status: number | null; output: string } {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    timeout: 30_000,
    killSignal: "SIGKILL",
  });
  const output = [result.stdout, result.stderr].join("\n");

  if (result.error) {
    throw new Error(
      `shared web test runner did not finish: ${result.error.message}\n${output}`,
    );
  }
  return { status: result.status, output };
}
