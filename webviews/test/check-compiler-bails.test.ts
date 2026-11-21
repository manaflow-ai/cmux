// The React Compiler bail ratchet (scripts/check-compiler-bails.mjs, reading skips through
// scripts/reactCompilerSkips.mjs): a function the compiler skips by each route counts, once, and a skip
// added to a file fails the check.
import { expect, test } from "bun:test";
import path from "node:path";
import { compareToBaseline, findBails } from "../scripts/check-compiler-bails.mjs";
import { compilerSkips } from "../scripts/reactCompilerSkips.mjs";

const file = path.resolve(import.meta.dir, "../src/agent-session/acpmux/Canary.tsx");
const lines = (found: string[]) => found.map((at) => Number(at.split(" ")[0]!.split(":").at(-1)));

const clean = ["export function Canary({ label }: { label: string }) {", "  return <b>{label}</b>;", "}"].join("\n");

test("a component that compiles is not a skip", () => {
  expect(findBails(file, clean)).toEqual([]);
});

test("a compile error skips the function, counted once at its first line however many errors it has", () => {
  const source = [
    "export function Canary({ label, run }: { label: string; run: () => void }) {",
    "  let held = 0;",
    "  try {",
    "    run();",
    "  } finally {",
    "    held ??= 1;",
    "  }",
    "  return <b>{label}{held}</b>;",
    "}",
  ].join("\n");
  const found = findBails(file, source);
  expect(lines(found)).toEqual([1]);
  expect(found[0]).toContain("TryStatement without a catch clause");
});

test('a "use no memo" opt-out is a skip (CompileSkip)', () => {
  const source = [
    "export function Canary({ label }: { label: string }) {",
    '  "use no memo";',
    "  return <b>{label}</b>;",
    "}",
  ].join("\n");
  const found = findBails(file, source);
  expect(found).toHaveLength(1);
  expect(found[0]).toContain("Skipped due to");
});

test("a pipeline error is a skip, and an error with no function falls back to its own location", () => {
  const events = [
    { kind: "PipelineError", fnLoc: { start: { line: 4 }, end: { line: 9 } }, data: "Error: invariant\n  at x" },
    {
      kind: "CompileError",
      fnLoc: null,
      detail: { options: { reason: "Hooks must be called", loc: { start: { line: 20 } } } },
    },
    { kind: "CompileError", fnLoc: null, detail: { reason: "Unexpected reference", loc: { start: { line: 31 } } } },
  ];
  expect(compilerSkips(events).map(({ line, kind, reason }) => [line, kind, reason])).toEqual([
    [4, "PipelineError", "Error: invariant"],
    [20, "CompileError", "Hooks must be called"],
    [31, "CompileError", "Unexpected reference"],
  ]);
});

test("a lint-only diagnostic inside a function that compiled is not a skip", () => {
  const events = [
    {
      kind: "CompileError",
      fnLoc: null,
      detail: { options: { reason: "setState in effect", loc: { start: { line: 6 } } } },
    },
    { kind: "CompileSuccess", fnLoc: { start: { line: 2 }, end: { line: 12 } }, fnName: "Canary" },
  ];
  expect(compilerSkips(events)).toEqual([]);
});

test("an opt-out logged as both its compile error and its skip counts once", () => {
  const events = [
    {
      kind: "CompileError",
      fnLoc: { start: { line: 3 }, end: { line: 10 } },
      detail: { options: { reason: "Ref in render" } },
    },
    {
      kind: "CompileSkip",
      fnLoc: { start: { line: 4 }, end: { line: 10 } },
      reason: "Skipped due to 'use no memo' directive.",
    },
  ];
  expect(compilerSkips(events).map((skip) => skip.line)).toEqual([3]);
});

test("a skip added to a file fails the check, by either route", () => {
  const relative = path.relative(path.resolve(import.meta.dir, ".."), file);
  const baseline = new Map([[relative, 0]]);
  for (const source of [
    clean.replace("{\n", '{\n  "use no memo";\n'),
    clean.replace("  return", "  try {\n  } finally {\n  }\n  return"),
  ]) {
    const found = new Map([[relative, findBails(file, source)]]);
    expect(compareToBaseline(found, baseline, () => true).grew).toHaveLength(1);
  }
  expect(compareToBaseline(new Map([[relative, findBails(file, clean)]]), baseline, () => true).grew).toEqual([]);
});
