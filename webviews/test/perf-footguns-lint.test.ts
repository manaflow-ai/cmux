import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const directory = mkdtempSync(join(tmpdir(), "cmux-perf-rule-"));
afterAll(() => rmSync(directory, { recursive: true, force: true }));
const config = resolve(import.meta.dir, "../scripts/lint/perf-footguns.json");
const vp = resolve(import.meta.dir, "../node_modules/.bin/vp");

type Diagnostic = { filename: string; code: string };

function lint(files: string[]): Diagnostic[] {
  const result = Bun.spawnSync([vp, "lint", "--config", config, "--format", "json", ...files], {
    cwd: resolve(import.meta.dir, ".."),
    stdout: "pipe",
    stderr: "pipe",
  });
  const output = new TextDecoder().decode(result.stdout);
  return (JSON.parse(output) as { diagnostics: Diagnostic[] }).diagnostics;
}

// [name, code, loop findings, read-after-write findings]
const cases = [
  [
    // #33624's base: each row measured between its siblings' writes.
    "rows measured and placed one by one",
    "export function place(rows: HTMLElement[]) { for (const row of rows) { const h = row.offsetHeight; row.style.top = `${h}px`; } }",
    1,
    0,
  ],
  [
    "per-item callback reads and writes",
    "export function fit(rows: HTMLElement[]) { rows.forEach((row) => { row.classList.add('fit'); row.getBoundingClientRect(); }); }",
    1,
    0,
  ],
  [
    "reads first, then writes",
    "export function place(rows: HTMLElement[]) { const hs = rows.map((row) => row.offsetHeight); rows.forEach((row, i) => { row.style.top = `${hs[i]}px`; }); }",
    0,
    0,
  ],
  [
    "a loop that only reads",
    "export function total(rows: HTMLElement[]) { let t = 0; for (const row of rows) t += row.getBoundingClientRect().height; return t; }",
    0,
    0,
  ],
  [
    "a style write assigned, not read",
    "export function size(rows: HTMLElement[]) { for (const row of rows) row.style.height = '10px'; }",
    0,
    0,
  ],
  [
    // #34711's base: the hover card wrote its place, then read its own rect.
    "one read after a write",
    "export function show(card: HTMLElement) { card.style.top = '4px'; return card.getBoundingClientRect(); }",
    0,
    1,
  ],
  [
    "a write-only loop, then a read",
    "export function size(rows: HTMLElement[], list: HTMLElement) { for (const row of rows) row.style.height = '10px'; return list.offsetHeight; }",
    0,
    1,
  ],
  [
    "one read before a write",
    "export function show(card: HTMLElement) { const r = card.getBoundingClientRect(); card.style.top = `${r.top}px`; }",
    0,
    0,
  ],
] as const;

test("the lint engine flags layout reads interleaved with writes, per item and in one turn", () => {
  const files = cases.map(([, code], index) => {
    const file = join(directory, `${index}.ts`);
    writeFileSync(file, code);
    return file;
  });
  const diagnostics = lint(files);
  for (const [index, [name, , loop, after]] of cases.entries()) {
    const own = diagnostics.filter((d) => d.filename.endsWith(`/${index}.ts`));
    expect(
      own.filter((d) => d.code.includes("layout-thrash-in-loop")),
      name,
    ).toHaveLength(loop);
    expect(
      own.filter((d) => d.code.includes("layout-read-after-write")),
      name,
    ).toHaveLength(after);
  }
}, 30_000);

test("putting Session Info's section reorder back to a read per section fails the loop rule", () => {
  const path = "src/agent-session/acpmux/session-info/SessionInfoGroup.tsx";
  const text = readFileSync(resolve(import.meta.dir, "..", path), "utf8");
  // The pre-guard shape: each section's offsetTop read inside the loop that restyles them.
  const mutation = text
    .replace(/const measured = Array\.from\([\s\S]*?\}\)\);\n/, "")
    .replace(
      "for (const { node, top, shift } of measured) {",
      'for (const node of root.querySelectorAll<HTMLElement>(":scope > [data-slot]")) { const top = node.offsetTop; const shift = drawnShift(node);',
    );
  expect(mutation).not.toBe(text);
  const file = join(directory, "SessionInfoGroup.tsx");
  writeFileSync(file, mutation);
  expect(lint([file]).some((d) => d.code.includes("layout-thrash-in-loop"))).toBe(true);
  expect(lint([resolve(import.meta.dir, "..", path)]).some((d) => d.code.includes("layout-thrash-in-loop"))).toBe(
    false,
  );
}, 30_000);

test("the dev server's save-time lint reads vp lint's JSON report", async () => {
  const { perfLintFindings } = await import("../dev-server/perfLint");
  const file = join(directory, "save.ts");
  writeFileSync(file, cases[0][1]);
  const result = Bun.spawnSync([vp, "lint", "--config", config, "--format", "json", file], {
    cwd: resolve(import.meta.dir, ".."),
    stdout: "pipe",
  });
  const findings = perfLintFindings(new TextDecoder().decode(result.stdout));
  expect(findings.map((f) => f.rule)).toEqual(["cmux-perf/layout-thrash-in-loop"]);
  expect(findings[0]?.line).toBe(1);
  expect(perfLintFindings("not json")).toEqual([]);
}, 30_000);
