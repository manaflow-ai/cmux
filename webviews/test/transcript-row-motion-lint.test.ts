// cmux-perf/transcript-row-motion (scripts/lint/perf-footguns.mjs): a transcript row may not move itself
// (cmuxterm-hq docs/design/transcript-motion-model.md, "What a row may not do"). Each ban planted in a
// row with no baseline fails; a marked use passes; the row components today stay inside their baseline.
import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { MOTION_MS } from "../src/motion/scale.generated";

const root = resolve(import.meta.dir, "..");
const directory = mkdtempSync(join(tmpdir(), "cmux-row-motion-"));
afterAll(() => rmSync(directory, { recursive: true, force: true }));
const config = join(directory, "row-motion.json");
writeFileSync(
  config,
  JSON.stringify({
    jsPlugins: [join(root, "scripts/lint/perf-footguns.mjs")],
    categories: { correctness: "off" },
    rules: { "cmux-perf/transcript-row-motion": "error" },
  }),
);
const vp = join(root, "node_modules/.bin/vp");

type Diagnostic = { filename: string; code: string; message: string };

function lint(files: string[]): Diagnostic[] {
  const result = Bun.spawnSync([vp, "lint", "--config", config, "--format", "json", ...files], {
    cwd: root,
    stdout: "pipe",
    stderr: "pipe",
  });
  return (JSON.parse(new TextDecoder().decode(result.stdout)) as { diagnostics: Diagnostic[] }).diagnostics;
}

const planted = [
  ["create a ResizeObserver", "export function Row(el: HTMLElement) { new ResizeObserver(() => {}).observe(el); }"],
  [
    "call flushSync",
    'import { flushSync } from "react-dom";\nexport function Row(set: () => void) { flushSync(set); }',
  ],
  ["set translate", "export function Row(el: HTMLElement) { el.style.translate = '0 4px'; }"],
  ["set translate", "export function Row(el: HTMLElement) { el.style.setProperty('transform', 'translateY(4px)'); }"],
  [
    "animate height",
    `export function Row(el: HTMLElement) { el.animate([{ height: '0px' }, { height: '40px' }], ${MOTION_MS.micro}); }`,
  ],
  ["animate height", `export function Row(el: HTMLElement) { el.style.transition = 'height ${MOTION_MS.micro}ms'; }`],
] as const;

test("each row-motion ban planted in a row with no baseline fails", () => {
  planted.forEach(([ban, code], index) => {
    const file = join(directory, `Planted${index}.tsx`);
    writeFileSync(file, `${code}\n`);
    const found = lint([file]).filter((d) => d.code.includes("transcript-row-motion"));
    expect(found.length).toBe(1);
    expect(found[0]?.message).toContain(`may not ${ban}`);
  });
}, 60_000);

test("a use marked row-motion-ok passes", () => {
  const file = join(directory, "Marked.tsx");
  writeFileSync(
    file,
    "export function Row(el: HTMLElement) {\n  // row-motion-ok: the find bar's own field, not a row\n  new ResizeObserver(() => {}).observe(el);\n}\n",
  );
  expect(lint([file]).filter((d) => d.code.includes("transcript-row-motion"))).toEqual([]);
}, 30_000);

test("today's row components stay inside scripts/lint/row-motion-baseline.json", () => {
  const files = ["conversation", "transcript"].flatMap((folder) => {
    const dir = join(root, "src/agent-session/acpmux", folder);
    return readdirSync(dir)
      .filter((name) => name.endsWith(".tsx") && !/\.(test|gallery|harness)\.tsx$/.test(name))
      .map((name) => join(dir, name));
  });
  expect(files.length).toBeGreaterThan(50);
  expect(lint(files).filter((d) => d.code.includes("transcript-row-motion"))).toEqual([]);
}, 120_000);
