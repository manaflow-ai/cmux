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
const ignoredFixtureTestSource = `
import { test } from "bun:test";
test("fixture stays ignored", () => {
  throw new Error("ignored fixture ran");
});
`;

test("shared web test runner isolates module mocks across files", () => {
  const result = runChild(
    "/bin/bash",
    [
      "scripts/run-tests.sh",
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

test("shared web test runner preserves sorted recursive discovery", () => {
  const fixtureRoot = createRunnerFixture();
  try {
    mkdirSync(join(fixtureRoot, ".hidden"));
    mkdirSync(join(fixtureRoot, "node_modules", "fixture"), {
      recursive: true,
    });
    mkdirSync(join(fixtureRoot, "tests", "nested"), { recursive: true });
    writeFileSync(
      join(fixtureRoot, "scripts", "alpha_spec.mts"),
      fixtureTestSource,
    );
    writeFileSync(
      join(fixtureRoot, "tests", "beta.test.ts"),
      fixtureTestSource,
    );
    writeFileSync(
      join(fixtureRoot, "tests", "nested", "gamma_test.tsx"),
      fixtureTestSource,
    );
    writeFileSync(
      join(fixtureRoot, "tests", "nested", "omega.spec.mjs"),
      fixtureTestSource,
    );
    writeFileSync(
      join(fixtureRoot, ".hidden", "ignored.test.ts"),
      ignoredFixtureTestSource,
    );
    writeFileSync(
      join(fixtureRoot, "node_modules", "fixture", "ignored.test.ts"),
      ignoredFixtureTestSource,
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
    const expectedHeadings = [
      "scripts/alpha_spec.mts:",
      "tests/beta.test.ts:",
      "tests/nested/gamma_test.tsx:",
      "tests/nested/omega.spec.mjs:",
    ];
    expectHeadingsInOrder(result.output, expectedHeadings);
    expect(result.output).not.toContain("ignored.test.ts:");

    const optionedResult = runChild(
      "/bin/bash",
      ["scripts/run-tests.sh", "-t", "fixture runs"],
      fixtureRoot,
    );
    if (optionedResult.status !== 0) {
      throw new Error(
        `option-only web test run lost discovery:\n${optionedResult.output}`,
      );
    }
    expectHeadingsInOrder(optionedResult.output, expectedHeadings);
    expect(optionedResult.output).not.toContain("ignored.test.ts:");

    const scopedResult = runChild(
      "/bin/bash",
      ["scripts/run-tests.sh", "--bail", "tests/beta.test.ts"],
      fixtureRoot,
    );
    if (scopedResult.status !== 0) {
      throw new Error(
        `optional Bun flag consumed a test filter:\n${scopedResult.output}`,
      );
    }
    expect(scopedResult.output).toContain("tests/beta.test.ts:");
    expect(scopedResult.output).not.toContain("scripts/alpha_spec.mts:");
    expect(scopedResult.output).not.toContain("tests/nested/");
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
    expect(result.output).toContain("No web test files found");
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

function expectHeadingsInOrder(output: string, headings: string[]): void {
  let previousIndex = -1;
  for (const heading of headings) {
    const index = output.indexOf(heading);
    expect(index).toBeGreaterThan(previousIndex);
    previousIndex = index;
  }
}
