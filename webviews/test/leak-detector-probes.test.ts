// Probes for the cross-file leak detector (test/support/leakDetector.ts): each one writes a small
// agent-session test file that leaves one kind of state behind, runs it in its own `bun test` with
// the detector strict, and checks the detector names what it left.
//
// - Object stores: a top-level const object, array or class instance a module keeps state in, and a
//   class's statics (dictation's `level` kept its waveform listeners after a strict pass).
// - Import-time registrations: a timer or listener a test file's static imports start while they
//   load, before the file's first line runs.
// - `once` listeners: one that never fired is still registered.
// - `let`-bound stores: a Map, Set, array or object a top-level `let` still holds, changed in place,
//   is named and put back, not only a `let` set to another value.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const webviews = new URL("..", import.meta.url).pathname;
const root = mkdtempSync(join(tmpdir(), "leak-probes-"));
const folder = join(root, "src/agent-session");
mkdirSync(folder, { recursive: true });
afterAll(() => rmSync(root, { recursive: true, force: true }));

/// Writes `files` under the probe's src/agent-session and runs `testFiles` strict, in one process; its
/// output.
async function probe(files: Record<string, string>, ...testFiles: string[]): Promise<{ code: number; output: string }> {
  for (const [name, source] of Object.entries(files)) writeFileSync(join(folder, name), source);
  const child = Bun.spawn(
    [
      "bun",
      "test",
      "--preload",
      join(webviews, "test/preload.ts"),
      ...testFiles.map((file) => `./src/agent-session/${file}`),
    ],
    {
      cwd: root,
      env: { ...process.env, CMUX_TEST_LEAKS: "strict", CMUX_TEST_LEAKS_RECORD: "" },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { code, output: `${stdout}\n${stderr}` };
}

test("an object, array, class instance or class static a module keeps state in is named", async () => {
  const dictation = join(webviews, "src/agent-session/acpmux/dictation.ts");
  const { code, output } = await probe(
    {
      "objectStore.ts": [
        "export const items: string[] = [];",
        "export const byName: Record<string, number> = {};",
        "export class Registry {",
        "  static live: string | undefined = undefined;",
        "}",
        "class Cache {",
        "  hits = 0;",
        "}",
        "export const cache = new Cache();",
        "export const TABLE = Object.freeze({ a: 1 });",
        "",
      ].join("\n"),
      "objectStore.test.ts": [
        'import { expect, test } from "bun:test";',
        `import { subscribeLevel } from ${JSON.stringify(dictation)};`,
        'import { byName, cache, items, Registry, TABLE } from "./objectStore";',
        'test("fills every store", () => {',
        '  items.push("a");',
        "  byName.a = 1;",
        '  Registry.live = "x";',
        "  cache.hits += 1;",
        "  subscribeLevel(() => {});",
        "  expect(TABLE.a).toBe(1);",
        "});",
        "",
      ].join("\n"),
    },
    "objectStore.test.ts",
  );
  expect(code).not.toBe(0);
  for (const name of ["items", "byName", "Registry", "cache"])
    expect(output).toContain(`src/agent-session/objectStore.ts \`${name}\` changed since it loaded`);
  expect(output).toContain("src/agent-session/acpmux/dictation.ts `level` changed since it loaded");
  expect(output).not.toContain("`TABLE`");
});

test("a timer and a listener a static import starts while it loads are the file's", async () => {
  const { code, output } = await probe(
    {
      "importTime.ts": [
        "setTimeout(() => {}, 60_000);",
        "const onProbe = () => {};",
        'globalThis.addEventListener("cmux-probe-import", onProbe);',
        "export const loaded = true;",
        "",
      ].join("\n"),
      "importTime.test.ts": [
        'import { expect, test } from "bun:test";',
        'import { loaded } from "./importTime";',
        'test("imports", () => {',
        "  expect(loaded).toBe(true);",
        "});",
        "",
      ].join("\n"),
    },
    "importTime.test.ts",
  );
  expect(code).not.toBe(0);
  expect(output).toContain("timer: a setTimeout from");
  expect(output).toContain("(src/agent-session/importTime.ts) is still pending");
  expect(output).toMatch(
    /listener: a "cmux-probe-import" listener on globalThis from .*\(src\/agent-session\/importTime\.ts\), added as it loaded/,
  );
});

test("a once listener that never fired is named; one that fired or was removed is not", async () => {
  const { code, output } = await probe(
    {
      "onceListener.test.ts": [
        'import { expect, test } from "bun:test";',
        'test("adds once listeners", () => {',
        "  let fired = 0;",
        '  globalThis.addEventListener("cmux-probe-unfired", () => {}, { once: true });',
        '  globalThis.addEventListener("cmux-probe-fired", () => (fired += 1), { once: true });',
        "  const removed = () => {};",
        '  globalThis.addEventListener("cmux-probe-removed", removed, { once: true });',
        '  globalThis.removeEventListener("cmux-probe-removed", removed);',
        '  globalThis.dispatchEvent(new Event("cmux-probe-fired"));',
        "  expect(fired).toBe(1);",
        "});",
        "",
      ].join("\n"),
    },
    "onceListener.test.ts",
  );
  expect(code).not.toBe(0);
  expect(output).toContain('listener: a "cmux-probe-unfired" listener on globalThis was not removed');
  expect(output).not.toContain('"cmux-probe-fired"');
  expect(output).not.toContain('"cmux-probe-removed"');
});

test("a let-bound Map, Set, array or object changed in place is named and put back", async () => {
  const { output } = await probe(
    {
      "letStore.ts": [
        "export let cache = new Map<string, number>();",
        "export let seen = new Set<string>();",
        "export let list: string[] = [];",
        "export let byName: Record<string, number> = {};",
        "export let untouched = new Map<string, number>();",
        "",
      ].join("\n"),
      "letStoreFills.test.ts": [
        'import { test } from "bun:test";',
        'import { byName, cache, list, seen } from "./letStore";',
        'test("fills every let-bound store in place", () => {',
        '  cache.set("a", 1);',
        '  seen.add("a");',
        '  list.push("a");',
        "  byName.a = 1;",
        "});",
        "",
      ].join("\n"),
      "letStoreReads.test.ts": [
        'import { expect, test } from "bun:test";',
        'import { byName, cache, list, seen } from "./letStore";',
        'test("starts on the loaded stores", () => {',
        "  expect({ cache: cache.size, seen: seen.size, list: list.length, byName: Object.keys(byName).length }).toEqual({",
        "    cache: 0,",
        "    seen: 0,",
        "    list: 0,",
        "    byName: 0,",
        "  });",
        "});",
        "",
      ].join("\n"),
    },
    "letStoreFills.test.ts",
    "letStoreReads.test.ts",
  );
  for (const name of ["cache", "seen", "list", "byName"])
    expect(output).toContain(`src/agent-session/letStore.ts \`${name}\` changed since it loaded`);
  expect(output).not.toContain("`untouched`");
  // The drain put the stores back, so the next file starts on them empty.
  expect(output).toContain("(pass) starts on the loaded stores");
});
