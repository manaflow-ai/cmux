// A browser file's own engine probe (its first launch) skips the file where the browser lane is
// optional and fails it where the lane is required, the same rule requireBrowserLane applies to the
// engines CI installs (#24458 review: a skip after requireBrowserLane passed reported a required
// file's tests as passing while none ran). The files probe through probeEngineOrSkip, so the rule
// tested here is the one they run: a file that skips with its own describe.skip fails this test.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import ts from "typescript";
import { browserLaneRequired, probeEngineOrSkip } from "./support/requireBrowserLane";

/// Playwright's launch timeout: a TimeoutError whose message goes on with the launch's call log.
const timeout = Object.assign(new Error("launch: Timeout 30000ms exceeded.\nCall log:\n  - <launched> pid=1"), {
  name: "TimeoutError",
});
const failing = () => Promise.reject(timeout);

/// Runs the probe with `launch` under `env`, recording what it reports and skips.
async function probe(env: Record<string, string>, launch: () => Promise<{ close(): Promise<void> }>) {
  const reports: string[] = [];
  const skips: string[] = [];
  const result = probeEngineOrSkip("thread minimap motion", "webkit", launch, {
    env,
    report: (line) => reports.push(line),
    skip: (name) => skips.push(name),
  });
  return { result, reports, skips };
}

test("on GitHub Actions the lane is required: a probe whose engine does not launch fails the file, naming the error", async () => {
  const env = { CI: "true", GITHUB_ACTIONS: "true" };
  expect(browserLaneRequired(env)).toBe(true);
  const { result, reports, skips } = await probe(env, failing);
  await expect(result).rejects.toThrow(
    /thread minimap motion: webkit did not launch \(TimeoutError: launch: Timeout 30000ms exceeded\.\)/,
  );
  expect(skips).toEqual([]);
  expect(reports).toEqual([]);
});

test("elsewhere the lane is optional: the probe skips the file and says why", async () => {
  for (const env of [
    // A fleet step that installs the engines (run-webviews-tests.sh with CMUX_BROWSER_TESTS=1).
    { CI: "true", CMUX_CI_STEP_KEY: "step", CMUX_BROWSER_TESTS: "1" },
    // A Freestyle VM or a laptop that asks for the lane.
    { CMUX_BROWSER_TESTS: "1" },
  ]) {
    expect(browserLaneRequired(env)).toBe(false);
    const { result, reports, skips } = await probe(env, failing);
    expect(await result).toBe(false);
    expect(skips).toEqual(["thread minimap motion"]);
    expect(reports).toEqual([
      "thread minimap motion: skipping, webkit did not launch here (TimeoutError: launch: Timeout 30000ms exceeded.); run `bunx playwright install webkit` if it is missing",
    ]);
  }
});

test("an engine that launches is closed again and the file goes on, required or not", async () => {
  for (const env of [{ CI: "true", GITHUB_ACTIONS: "true" }, { CMUX_BROWSER_TESTS: "1" }]) {
    let closed = 0;
    const { result, reports, skips } = await probe(env, async () => ({ close: async () => void (closed += 1) }));
    expect(await result).toBe(true);
    expect(closed).toBe(1);
    expect(skips).toEqual([]);
    expect(reports).toEqual([]);
  }
});

// A launched browser whose close() rejects is neither a skip nor a leak: the probe tries close()
// again, and if that fails too it rejects, required or not (#24458 review round 3).
test("a browser that launches but does not close is closed again, and never makes the file skip", async () => {
  for (const env of [{ CI: "true", GITHUB_ACTIONS: "true" }, { CMUX_BROWSER_TESTS: "1" }]) {
    // Once: the second close() closes it, and the file goes on.
    let closes = 0;
    const once = await probe(env, async () => ({
      close: async () => {
        closes += 1;
        if (closes === 1) throw new Error("Target page, context or browser has been closed");
      },
    }));
    expect(await once.result).toBe(true);
    expect(closes).toBe(2);
    expect(once.skips).toEqual([]);
    // Always: the probe rejects, naming the close error; it does not report a skip.
    let tries = 0;
    const never = await probe(env, async () => ({
      close: async () => {
        tries += 1;
        throw new Error("close failed");
      },
    }));
    await expect(never.result).rejects.toThrow(/thread minimap motion: webkit launched but did not close \(Error: close failed\)/);
    expect(tries).toBe(2);
    expect(never.skips).toEqual([]);
    expect(never.reports).toEqual([]);
  }
});

test("the probe uses a bounded launch and closes the browser", async () => {
  const options: unknown[] = [];
  const { result, reports, skips } = await probe(
    { CI: "true", CMUX_BROWSER_TESTS: "1" },
    async (launchOptions?: unknown) => {
      options.push(launchOptions);
      return { close: async () => {} };
    },
  );
  expect(await result).toBe(true);
  expect(options).toEqual([{ headless: true, timeout: 30_000 }]);
  expect(skips).toEqual([]);
  expect(reports).toEqual([]);
});

/// What keeps `file` (its source `text`) from failing where the lane is required: no call of
/// probeEngineOrSkip, or a skip of its own (a describe, test or it `.skip`), which would report the
/// file's tests as passing on GitHub Actions with none run.
function probedSourceProblems(file: string, text: string): string[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  // The helper's local name, from its import (a same-named function of the file's own is not it).
  let helper: string | undefined;
  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier)) continue;
    if (!/(?:^|\/)support\/requireBrowserLane(?:\.ts)?$/.test(statement.moduleSpecifier.text)) continue;
    const bindings = statement.importClause?.namedBindings;
    if (statement.importClause?.isTypeOnly || !bindings || !ts.isNamedImports(bindings)) continue;
    for (const binding of bindings.elements)
      if (!binding.isTypeOnly && (binding.propertyName ?? binding.name).text === "probeEngineOrSkip") helper = binding.name.text;
  }
  const problems: string[] = [];
  let probes = false;
  let shadowed = false;
  const visit = (node: ts.Node) => {
    if (helper && ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === helper) probes = true;
    // A declaration of the helper's name past the import shadows it.
    if (
      helper &&
      (ts.isVariableDeclaration(node) || ts.isFunctionDeclaration(node) || ts.isParameter(node)) &&
      node.name &&
      ts.isIdentifier(node.name) &&
      node.name.text === helper
    )
      shadowed = true;
    // describe.skip, test.skip, it.skip (and skipIf), called or passed on: `describe.skip(...)`,
    // `describe.skip.each(...)`, `describe["skip"](...)`.
    const access = ts.isPropertyAccessExpression(node)
      ? { object: node.expression, name: node.name.text }
      : ts.isElementAccessExpression(node) && ts.isStringLiteralLike(node.argumentExpression)
        ? { object: node.expression, name: node.argumentExpression.text }
        : undefined;
    if (
      access &&
      ts.isIdentifier(access.object) &&
      ["describe", "test", "it"].includes(access.object.text) &&
      (access.name === "skip" || access.name === "skipIf")
    )
      problems.push(`${file}: ${access.object.text}.${access.name}`);
    ts.forEachChild(node, visit);
  };
  visit(source);
  if (!probes || shadowed) problems.push(`${file}: no probeEngineOrSkip call`);
  return problems;
}

/// The files whose engine probe goes through probeEngineOrSkip: none skips itself, so a failed
/// launch where the lane is required fails it.
const PROBED = ["thread-minimap-motion.test.ts"];

test("the probed files skip only through probeEngineOrSkip", () => {
  for (const file of PROBED)
    expect(probedSourceProblems(file, readFileSync(new URL(`./${file}`, import.meta.url), "utf8"))).toEqual([]);
});

// The check reads code, not text: a string or a comment that names the helper or a skip changes
// nothing (#24458 review round 3).
test("the probe check reads code: strings and comments neither hide a skip nor stand in for the call", () => {
  const head = 'import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";\n';
  const probe = '  if (!(await probeEngineOrSkip("m", "webkit", () => webkit.launch()))) return;\n';
  const lane = (body: string) => `${head}await requireBrowserLane("m", async () => {\n${body}});\n`;
  // A skip after a string that holds "//".
  expect(probedSourceProblems("a", lane(`${probe}  const url = \`http://127.0.0.1:\${port}/\`; describe.skip("m", () => {});\n`))).toEqual([
    "a: describe.skip",
  ]);
  // The call only in a string, and in a comment.
  expect(probedSourceProblems("b", lane('  const name = "probeEngineOrSkip(";\n  // probeEngineOrSkip(\n'))).toEqual([
    "b: no probeEngineOrSkip call",
  ]);
  // A skip named in a string or a comment is not one; test.skip and it.skip are.
  expect(probedSourceProblems("c", lane(`${probe}  const note = "describe.skip";\n  /* test.skip */\n`))).toEqual([]);
  expect(probedSourceProblems("d", lane(`${probe}  test.skip("x", () => {});\n  it.skip("y", () => {});\n`))).toEqual([
    "d: test.skip",
    "d: it.skip",
  ]);
  // A local function of the same name is not the helper.
  expect(
    probedSourceProblems(
      "e",
      'await requireBrowserLane("m", async () => {\n  const probeEngineOrSkip = async () => true;\n  await probeEngineOrSkip();\n});\n',
    ),
  ).toEqual(["e: no probeEngineOrSkip call"]);
});
