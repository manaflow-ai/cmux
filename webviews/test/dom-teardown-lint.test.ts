// The detector for teardowns that delete DOM globals while React still has work queued (the class
// test/support/domTeardown.ts explains: "window is not defined" between tests, 0 failed tests).
// Every webviews test file that installs its own window and deletes globals must import
// test/support/domTeardown and tear down through `teardownDom` or after `await settleReact()`.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const webviews = resolve(import.meta.dir, "..");

/// A file that makes its own DOM (JSDOM, happy-dom).
const installsDom = /new JSDOM\(|happy-dom|GlobalRegistrator|new Window\(/;
/// A teardown that deletes globals: `delete scope[key]`, `delete globalThis.window`, Reflect.deleteProperty.
const deletesGlobals =
  /delete \w+\[\w+\]|delete (?:globalThis|scope|globals|global|g)\.(?:window|document)\b|Reflect\.deleteProperty\(/;
/// The helper, imported from any folder.
const usesHelper = /from "(?:\.\.?\/)+(?:test\/)?support\/domTeardown"/;

export function teardownFinding(source: string): string | undefined {
  if (!installsDom.test(source) || !deletesGlobals.test(source)) return undefined;
  if (usesHelper.test(source) && /\b(?:teardownDom|settleReact)\(/.test(source)) return undefined;
  return "deletes DOM globals without test/support/domTeardown (teardownDom, or await settleReact() first)";
}

function testFiles(): string[] {
  const listed = Bun.spawnSync(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.test.ts", "*.test.tsx"],
    {
      cwd: webviews,
      stdout: "pipe",
    },
  );
  return (
    new TextDecoder()
      .decode(listed.stdout)
      .split("\0")
      // dom-teardown-settles.test.ts's fixtures (gitignored; a run beside this one can still list them).
      .filter((name) => name && !name.startsWith("test/support/") && !name.includes("/.dom-teardown-"))
  );
}

// One test per offending file, named by the file. Pull requests excuse a red that is red on the base by
// its test name, so a single test listing every offender let a new offender (draftSettleHold.test.tsx,
// #43591) hide behind an old one (failed-send-keeps-prompt.test.ts, #43462) for the whole base red.
// With a test per file a new offender is a new red name (handbook: excuse-key-drops-identity).
const files = testFiles();
const offenders = files.flatMap((name) => {
  const finding = teardownFinding(readFileSync(resolve(webviews, name), "utf8"));
  return finding ? [{ name, finding }] : [];
});

test("every test file that deletes DOM globals settles React first", () => {
  expect(files.length).toBeGreaterThan(100);
});

for (const { name, finding } of offenders) {
  test(`settles React before teardown > ${name}`, () => {
    expect(`${name}: ${finding}`).toBe(`${name}: settles React before teardown`);
  });
}

test("the rule flags a hand-rolled teardown and passes the helper", () => {
  const install = 'const dom = new JSDOM("<!doctype html>");\n';
  const handRolled = `${install}afterAll(() => {\n  dom.window.close();\n  for (const [key, had, value] of saved) {\n    if (had) scope[key] = value;\n    else delete scope[key];\n  }\n});\n`;
  expect(teardownFinding(handRolled)).toBeDefined();
  expect(teardownFinding(`${install}afterAll(() => { delete globalThis.window; });\n`)).toBeDefined();
  expect(
    teardownFinding(
      `import { teardownDom } from "./support/domTeardown";\n${install}afterAll(() => teardownDom(saved, { window: dom.window }));\n`,
    ),
  ).toBeUndefined();
  // Imported but never called is still the hand-rolled teardown.
  expect(
    teardownFinding(`import { settleReact } from "../../../test/support/domTeardown";\n${handRolled}`),
  ).toBeDefined();
  expect(
    teardownFinding(
      `import { settleReact } from "../../../test/support/domTeardown";\n${handRolled.replace("{\n", "{\n  await settleReact();\n")}`,
    ),
  ).toBeUndefined();
  // No DOM of its own: deleting other keys is not this class.
  expect(teardownFinding("afterAll(() => { delete cache[key]; });\n")).toBeUndefined();
});
