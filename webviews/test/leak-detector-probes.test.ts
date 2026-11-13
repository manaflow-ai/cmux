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
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const webviews = new URL("..", import.meta.url).pathname;
const root = mkdtempSync(join(tmpdir(), "leak-probes-"));
const folder = join(root, "src/agent-session");
mkdirSync(folder, { recursive: true });
afterAll(() => rmSync(root, { recursive: true, force: true }));

/// Writes `files` under the probe's src/agent-session and runs `testFiles` strict, in one process; its
/// output.
function probe(files: Record<string, string>, ...testFiles: string[]): Promise<{ code: number; output: string }> {
  return probeWith({}, files, ...testFiles);
}

/// probe with `env` over the strict defaults (CMUX_TEST_LEAKS, a baseline of its own).
async function probeWith(
  env: Record<string, string>,
  files: Record<string, string>,
  ...testFiles: string[]
): Promise<{ code: number; output: string }> {
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
      env: { ...process.env, CMUX_TEST_LEAKS: "strict", CMUX_TEST_LEAKS_RECORD: "", ...env },
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

test("the ratchet compares leaks by name: a baseline leak swapped for another at the same count fails", async () => {
  // swap.test.ts leaves `a` set; the baseline lists one leak, `a` or else `b`.
  const files = {
    "swapStore.ts": [
      "export let a = 0;",
      "export let b = 0;",
      "export function setA(): void {",
      "  a = 1;",
      "}",
      "",
    ].join("\n"),
    "swap.test.ts": [
      'import { test } from "bun:test";',
      'import { setA } from "./swapStore";',
      'test("sets a", () => setA());',
      "",
    ].join("\n"),
  };
  const item = (name: string) => `module state: src/agent-session/swapStore.ts \`${name}\` is still set`;
  const baselineFile = join(root, "swap-baseline.json");
  const run = (allowed: string[]) => {
    writeFileSync(baselineFile, JSON.stringify({ "src/agent-session/swap.test.ts": allowed }));
    return probeWith({ CMUX_TEST_LEAKS: "on", CMUX_TEST_LEAKS_BASELINE: baselineFile }, files, "swap.test.ts");
  };
  // The leak it lists: allowed.
  const listed = await run([item("a")]);
  expect(listed.output).toContain("(pass) sets a");
  expect(listed.code).toBe(0);
  // Another leak at the same count: the new one is named and the file fails.
  const swapped = await run([item("b")]);
  expect(swapped.code).not.toBe(0);
  expect(swapped.output).toContain(`  ${item("a")}`);
  // A listed item the file no longer leaves is reported stale, by name; it fails nothing.
  const stale = await run([item("a"), item("b")]);
  expect(stale.code).toBe(0);
  expect(stale.output).toContain(`no longer leaves ${item("b")}`);
});

test("an array's length is part of its state: `length = n` on an empty array is named and put back", async () => {
  const { code, output } = await probe(
    {
      "lengthStore.ts": ["export const items: string[] = [];", "export const box = { list: [] as string[] };", ""].join(
        "\n",
      ),
      "lengthGrows.test.ts": [
        'import { test } from "bun:test";',
        'import { box, items } from "./lengthStore";',
        'test("grows both arrays by length alone", () => {',
        "  items.length = 10;",
        "  box.list.length = 3;",
        "});",
        "",
      ].join("\n"),
      "lengthReads.test.ts": [
        'import { expect, test } from "bun:test";',
        'import { box, items } from "./lengthStore";',
        'test("starts on the loaded lengths", () => {',
        "  expect([items.length, box.list.length]).toEqual([0, 0]);",
        "});",
        "",
      ].join("\n"),
    },
    "lengthGrows.test.ts",
    "lengthReads.test.ts",
  );
  expect(code).not.toBe(0);
  for (const name of ["items", "box"])
    expect(output).toContain(`src/agent-session/lengthStore.ts \`${name}\` changed since it loaded`);
  expect(output).toContain("(pass) starts on the loaded lengths");
});

test("baseline regeneration keeps the entries of a file that failed or wrote no record", async () => {
  // scripts/leak-baseline.ts in a root of its own: its baseline, a preload with the detector, three files.
  const regen = mkdtempSync(join(tmpdir(), "leak-regen-"));
  try {
    mkdirSync(join(regen, "scripts"));
    mkdirSync(join(regen, "test/support"), { recursive: true });
    mkdirSync(join(regen, "src/agent-session"), { recursive: true });
    mkdirSync(join(regen, "src/other"), { recursive: true });
    copyFileSync(join(webviews, "scripts/leak-baseline.ts"), join(regen, "scripts/leak-baseline.ts"));
    writeFileSync(
      join(regen, "bunfig.toml"),
      `[test]\npreload = [${JSON.stringify(join(webviews, "test/preload.ts"))}]\n`,
    );
    const files: Record<string, string> = {
      // Fails: what it would leave is unknown, so its entry stays.
      "src/agent-session/fails.test.ts":
        'import { test } from "bun:test";\ntest("fails", () => { throw new Error("no"); });\n',
      // Passes and leaves nothing: its entry is lowered away.
      "src/agent-session/clean.test.ts": 'import { test } from "bun:test";\ntest("passes", () => {});\n',
      // Passes, but the detector never checks it, so it writes no record: its entry stays.
      "src/other/quiet.test.ts": 'import { test } from "bun:test";\ntest("passes", () => {});\n',
    };
    for (const [name, source] of Object.entries(files)) writeFileSync(join(regen, name), source);
    const left = "module state: src/agent-session/gone.ts `x` is still set";
    const baselineFile = join(regen, "test/support/leak-baseline.json");
    writeFileSync(baselineFile, JSON.stringify(Object.fromEntries(Object.keys(files).map((file) => [file, [left]]))));
    const child = Bun.spawn(["bun", join(regen, "scripts/leak-baseline.ts"), ...Object.keys(files)], {
      cwd: regen,
      env: { ...process.env, CMUX_TEST_LEAKS: "", CMUX_TEST_LEAKS_RECORD: "" },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    const output = `${stdout}\n${stderr}`;
    expect(JSON.parse(readFileSync(baselineFile, "utf8"))).toEqual({
      "src/agent-session/fails.test.ts": [left],
      "src/other/quiet.test.ts": [left],
    });
    expect(code).not.toBe(0);
    expect(output).toContain("src/agent-session/fails.test.ts");
    expect(output).toContain("src/other/quiet.test.ts");
  } finally {
    rmSync(regen, { recursive: true, force: true });
  }
});
