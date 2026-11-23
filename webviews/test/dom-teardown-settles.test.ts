// The forced repro for test/support/domTeardown.ts: a file whose React root takes an update outside
// act() right before its teardown. With the hand-rolled teardown (close the window, delete the
// globals) React's queued scheduler task runs with no `window` and bun fails the file with "window
// is not defined" and 0 failed tests, every time; with teardownDom the same file passes. Each case
// runs as its own `bun test` process, as the webviews runner runs each file.
import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const webviews = resolve(import.meta.dir, "..");
// Inside test/ so the fixture resolves react and jsdom and gets bunfig's preload, as a real file does.
const directory = mkdtempSync(join(import.meta.dir, ".dom-teardown-"));
afterAll(() => rmSync(directory, { recursive: true, force: true }));

function fixture(teardown: string): string {
  return `import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { reactHasPendingWork, teardownDom } from "../support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let bump = () => {};

function Counter() {
  const [count, setCount] = useState(0);
  bump = () => setCount((value) => value + 1);
  return <p>{count}</p>;
}

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
});

afterAll(async () => {
  // An update outside act(): React schedules its render on the scheduler (setImmediate).
  bump();
  await Promise.resolve();
  if (!reactHasPendingWork()) throw new Error("the repro queued no React work");
  ${teardown}
});

test("renders", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<Counter />));
  expect(dom.window.document.querySelector("p")?.textContent).toBe("0");
});
`;
}

const handRolled = `dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }`;

function run(name: string, teardown: string) {
  const file = join(directory, `${name}.test.tsx`);
  writeFileSync(file, fixture(teardown));
  const result = Bun.spawnSync([process.execPath, "test", file], { cwd: webviews, stdout: "pipe", stderr: "pipe" });
  return {
    code: result.exitCode,
    output: new TextDecoder().decode(result.stdout) + new TextDecoder().decode(result.stderr),
  };
}

test("the hand-rolled teardown fails the file with window is not defined", () => {
  const { code, output } = run("hand-rolled", handRolled);
  expect(output).toContain("window is not defined");
  expect(code).not.toBe(0);
}, 60_000);

test("teardownDom lets React finish first, and the file passes", () => {
  const { code, output } = run(
    "settled",
    'await teardownDom(saved, { window: dom.window });\n  if (reactHasPendingWork()) throw new Error("work left after teardownDom");',
  );
  expect(output).not.toContain("window is not defined");
  expect(output).not.toContain("Unhandled error");
  expect(code).toBe(0);
}, 60_000);
