import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FIXED_BYTES_LIMIT, MEDIA, fixedBytes, mediaOf, plan, redStates } from "./upload-set";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const result = (entry: string, variant: string, theme: string) => {
  const shot = `${entry}_${variant}_${theme}-chromium`;
  return {
    id: `${entry}#${variant}@${theme}`,
    engine: "chromium",
    screenshot: `${shot}.png`,
    params: { entry, variant, colorScheme: theme },
    ready: "1",
    play: { stills: [{ index: 0, step: "open", screenshot: `${shot}--step-01.png` }] },
    workflowEvidence: { beforeSteps: [{ index: 0, screenshot: `${shot}--step-01-before.png` }], afterSteps: [] },
  };
};

/** A shard as health.ts writes it: `cases` states, two themes each, a screenshot and two stills a case. */
function shard(cases: number, health: Record<string, unknown> | null, red: string[] = []) {
  const dir = mkdtempSync(join(tmpdir(), "upload-set-"));
  dirs.push(dir);
  const write = (path: string, body: string | Buffer) => {
    mkdirSync(join(dir, path, ".."), { recursive: true });
    writeFileSync(join(dir, path), body);
  };
  const png = Buffer.alloc(80 * 1024, 1); // a full render's screenshots average ~85 KB
  const results = Array.from({ length: cases }, (_, i) => ["light", "dark"].map((theme) => result(`ui.entry${i}`, "default", theme))).flat();
  const writeAttempt = (folder: string, list: typeof results) => {
    write(`${folder}/results.json`, JSON.stringify(list, null, 2));
    write(`${folder}/index.html`, `<script>const results=${JSON.stringify(list)}</script>`);
    for (const item of list) for (const name of mediaOf(item)) write(`${folder}/${name}`, png);
  };
  writeAttempt("attempt-0", results);
  const redResults = results.filter((item) => red.includes(`${item.params.entry}#${item.params.variant}`));
  if (red.length) {
    writeAttempt("attempt-1", redResults);
    writeAttempt("base/1/attempt-0", redResults);
  }
  if (health) write("health.json", JSON.stringify(health));
  write("source.json", "{}");
  write("shard.json", JSON.stringify(results.map(({ id, params }) => ({ id, params }))));
  return dir;
}

const verdict = (fresh: string[] = []) => ({ fresh: fresh.map((state) => ({ state, reason: "never reported ready" })), known: [], fixed: [], slow: [], shifted: [], geometry: [] });
const statesOf = (dir: string, paths: string[]) => {
  const named = new Map<string, string>();
  for (const path of paths.filter((file) => file.endsWith("results.json")))
    for (const item of JSON.parse(readFileSync(join(dir, path), "utf8")))
      for (const name of mediaOf(item)) named.set(join(path, "..", name).replace(/^\.\//, ""), `${item.params.entry}#${item.params.variant}`);
  return named;
};

test("the upload carries no passing state's screenshot", () => {
  const dir = shard(40, verdict(["ui.entry3#default"]), ["ui.entry3#default"]);
  const { keep, drop } = plan(dir);
  const named = statesOf(dir, [...keep, ...drop]);
  const kept = keep.filter((path) => MEDIA.test(path));
  // Every kept screenshot is the red state's, in each attempt and the base replay; every other one goes.
  expect(kept.length).toBe(3 * 2 * 3);
  for (const path of kept) expect(named.get(path)).toBe("ui.entry3#default");
  expect(drop.every((path) => named.get(path) !== "ui.entry3#default")).toBe(true);
  expect(drop.length).toBe(39 * 2 * 3);
  // What the readers read stays.
  for (const path of ["health.json", "source.json", "attempt-0/results.json", "attempt-1/results.json", "base/1/attempt-0/results.json"])
    expect(keep).toContain(path);
});

test("a run with no red state uploads no screenshot, and stays under the ratchet", () => {
  // A full render's shard holds ~300 states; 2,334 screenshots.
  const dir = shard(300, verdict());
  const { keep, drop } = plan(dir);
  expect(keep.filter((path) => MEDIA.test(path))).toEqual([]);
  expect(drop.length).toBe(300 * 2 * 3);
  expect(fixedBytes(dir, keep)).toBeLessThan(FIXED_BYTES_LIMIT);
});

test("every red kind keeps its screenshots: broken, allowlisted, slow, shifted, past geometry", () => {
  const kinds = ["fresh", "known", "slow", "shifted", "geometry"];
  const health = { ...verdict(), ...Object.fromEntries(kinds.map((key, i) => [key, [{ state: `ui.entry${i}#default` }]])) };
  expect([...redStates(JSON.stringify(health))!].sort()).toEqual(kinds.map((_, i) => `ui.entry${i}#default`));
  const { keep } = plan(shard(8, health));
  expect(keep.filter((path) => MEDIA.test(path)).length).toBe(kinds.length * 2 * 3);
});

test("a shard with no verdict keeps every screenshot", () => {
  expect(redStates(null)).toBeNull();
  expect(redStates("{\"error\": \"gallery health could not render: browser\"}")).toBeNull();
  expect(redStates("not json")).toBeNull();
  for (const health of [null, { error: "could not render" }]) expect(plan(shard(4, health)).drop).toEqual([]);
});

test("--keep names more: a state, an entry, or all", () => {
  const dir = shard(6, verdict());
  const kept = (requested: string[]) => plan(dir, requested).keep.filter((path) => MEDIA.test(path)).length;
  expect(kept([])).toBe(0);
  expect(kept(["ui.entry1#default"])).toBe(2 * 3);
  expect(kept(["ui.entry2"])).toBe(2 * 3);
  expect(kept(["all"])).toBe(6 * 2 * 3);
});

test("a screenshot named by no result is dropped once there is a verdict", () => {
  const dir = shard(2, verdict());
  writeFileSync(join(dir, "attempt-0", "stray.png"), "x");
  expect(plan(dir).drop).toContain("attempt-0/stray.png");
});
