import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const directory = mkdtempSync(join(tmpdir(), "cmux-interval-rule-"));
afterAll(() => rmSync(directory, { recursive: true, force: true }));
const config = resolve(import.meta.dir, "../scripts/lint/effect-cleanup.json");
const vp = resolve(import.meta.dir, "../node_modules/.bin/vp");
const prefix = 'import React, { useEffect, useEffect as effect, useLayoutEffect } from "react";\n';
const cases = [
  [
    "unrelated async work after cleanup",
    "async function flush() { await Promise.resolve(); recordFlush(); } useEffect(() => { const id = setInterval(tick, 1000); return () => { clearInterval(id); void flush(); }; }, []);",
    0,
  ],
  [
    "chained cleanup helper restart",
    "useEffect(() => { let id = setInterval(tick, 1000); function restart() { clearInterval(id); id = setInterval(tick, 1000); } function stop() { restart(); } return () => stop(); }, []);",
    2,
  ],
  [
    "cyclic helper scan terminates",
    "useEffect(() => { const id = setInterval(tick, 1000); function stop() { clearInterval(id); if (again) stop(); } return () => stop(); }, []);",
    0,
  ],
  [
    "cleanup helper restart",
    "useEffect(() => { let id = setInterval(tick, 1000); function restart() { clearInterval(id); id = setInterval(tick, 1000); } return () => restart(); }, []);",
    2,
  ],
  [
    "rest destructured handle overwrite",
    "useEffect(() => { let id = setInterval(tick, 1000); [...[id]] = [0]; return () => clearInterval(id); }, []);",
    1,
  ],
  ["conditional effect callback", "useEffect(active ? () => { setInterval(tick, 1000); } : () => {}, []);", 1],
  [
    "destructured handle overwrite",
    "useEffect(() => { let id = setInterval(tick, 1000); [id] = [0]; return () => clearInterval(id); }, []);",
    1,
  ],
  [
    "cleanup restart leak",
    "useEffect(() => { let id = setInterval(tick, 1000); return () => { clearInterval(id); id = setInterval(tick, 1000); }; }, []);",
    2,
  ],
  [
    "async effect cannot register cleanup",
    "useEffect(async () => { const id = setInterval(tick, 1000); return () => clearInterval(id); }, []);",
    1,
  ],
  [
    "guarded allocation",
    "useEffect(() => { if (active) { const id = setInterval(tick, 1000); return () => clearInterval(id); } }, [active]);",
    0,
  ],
  [
    "unrelated inactive branch return",
    "useEffect(() => { if (active) { const id = setInterval(tick, 1000); return () => clearInterval(id); } else { return; } }, [active]);",
    0,
  ],
  [
    "switch cleanup exit",
    'useEffect(() => { const id = setInterval(tick, 1000); return () => { switch (mode) { case "skip": return; } clearInterval(id); }; }, []);',
    1,
  ],
  [
    "loop cleanup exit",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => { for (const item of items) { if (item) return; } clearInterval(id); }; }, []);",
    1,
  ],
  [
    "try cleanup exit",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => { try { if (skip) return; } catch {} clearInterval(id); }; }, []);",
    1,
  ],
  [
    "finally clears despite return",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => { try { if (skip) return; } finally { clearInterval(id); } }; }, []);",
    0,
  ],
  [
    "switch effect exit",
    'useEffect(() => { const id = setInterval(tick, 1000); switch (mode) { case "skip": return; } return () => clearInterval(id); }, []);',
    1,
  ],
  [
    "shared outer handle",
    "let id; useEffect(() => { id = setInterval(tick, 1000); return () => clearInterval(id); }, []);",
    1,
  ],
  [
    "overwritten cleanup helper",
    "useEffect(() => { const id = setInterval(tick, 1000); let stop = () => clearInterval(id); stop = () => {}; return stop; }, []);",
    1,
  ],
  ["leak", "useEffect(() => { setInterval(tick, 1000); }, []);", 1],
  ["unrelated cleanup", "useEffect(() => { const id = setInterval(tick, 1000); return () => stop(); }, []);", 1],
  [
    "other handle",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => clearInterval(other); }, []);",
    1,
  ],
  [
    "shadowed handle",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => { const id = 2; clearInterval(id); }; }, []);",
    1,
  ],
  [
    "nested uncalled cleanup",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => { const stop = () => clearInterval(id); }; }, []);",
    1,
  ],
  [
    "nested callback cleanup",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => later(() => clearInterval(id)); }, []);",
    1,
  ],
  [
    "wrong effect",
    "useEffect(() => { const id = setInterval(tick, 1000); }, []); useEffect(() => () => clearInterval(id), []);",
    1,
  ],
  [
    "return in nested function",
    "useEffect(() => { const id = setInterval(tick, 1000); const f = () => { return () => clearInterval(id); }; }, []);",
    1,
  ],
  [
    "return on one branch",
    "useEffect(() => { const id = setInterval(tick, 1000); if (skip) return; return () => clearInterval(id); }, []);",
    1,
  ],
  [
    "effect fallthrough",
    "useEffect(() => { const id = setInterval(tick, 1000); if (active) return () => clearInterval(id); }, []);",
    1,
  ],
  [
    "conditional clear",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => { if (skip) clearInterval(id); }; }, []);",
    1,
  ],
  [
    "unreachable clear",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => { if (skip) return; clearInterval(id); }; }, []);",
    1,
  ],
  ["aliased effect", "effect(() => { const id = setInterval(tick, 1000); }, []);", 1],
  ["layout leak", "useLayoutEffect(() => { const id = setInterval(tick, 1000); }, []);", 1],
  ["namespace leak", "React.useEffect(() => { const id = window.setInterval(tick, 1000); }, []);", 1],
  [
    "nested event leak",
    "useEffect(() => { let id; const start = () => { id = setInterval(tick, 1000); }; start(); }, []);",
    1,
  ],
  ["named effect leak", "const start = () => { const id = setInterval(tick, 1000); }; useEffect(start, []);", 1],
  [
    "overwritten handle",
    "useEffect(() => { let id = setInterval(tick, 1000); id = setInterval(tick, 1000); return () => clearInterval(id); }, []);",
    1,
  ],
  [
    "discarded handle",
    "useEffect(() => { let id = setInterval(tick, 1000); id = undefined; return () => clearInterval(id); }, []);",
    1,
  ],
  [
    "async cleanup",
    "useEffect(() => { const id = setInterval(tick, 1000); return async () => { await wait(); clearInterval(id); }; }, []);",
    1,
  ],
  [
    "async helper",
    "useEffect(() => { const id = setInterval(tick, 1000); const stop = async () => { await wait(); clearInterval(id); }; return () => stop(); }, []);",
    1,
  ],
  [
    "cleared before restart",
    "useEffect(() => { let id = setInterval(tick, 1000); clearInterval(id); id = setInterval(tick, 1000); return () => clearInterval(id); }, []);",
    0,
  ],
  [
    "direct cleanup",
    "useEffect(() => { const id = setInterval(tick, 1000); return () => clearInterval(id); }, []);",
    0,
  ],
  [
    "window cleanup",
    "React.useEffect(() => { const id = window.setInterval(tick, 1000); return () => window.clearInterval(id); }, []);",
    0,
  ],
  [
    "global cleanup",
    "effect(() => { const id = globalThis.setInterval(tick, 1000); return () => globalThis.clearInterval(id); }, []);",
    0,
  ],
  [
    "early inactive exit",
    "useEffect(() => { if (!active) return; const id = setInterval(tick, 1000); return () => clearInterval(id); }, []);",
    0,
  ],
  [
    "optional interval",
    "useEffect(() => { const id = active ? setInterval(tick, 1000) : undefined; return () => { if (id) clearInterval(id); }; }, []);",
    0,
  ],
  [
    "nested start and named cleanup",
    "useEffect(() => { let id; const start = () => { clearInterval(id); id = setInterval(tick, 1000); }; const stop = () => clearInterval(id); start(); return stop; }, []);",
    0,
  ],
  [
    "cleanup calls helper",
    "useEffect(() => { const id = setInterval(tick, 1000); function stop() { clearInterval(id); } return () => stop(); }, []);",
    0,
  ],
  [
    "both teardown branches",
    "useEffect(() => { const id = setInterval(tick, 1000); if (a) return () => clearInterval(id); return () => clearInterval(id); }, []);",
    0,
  ],
  ["unrelated API", "const useEffect = (f) => f(); useEffect(() => { setInterval(tick, 1000); });", 0],
  [
    "non React lifecycle",
    "function subscribe() { const id = setInterval(tick, 1000); return () => clearInterval(id); }",
    0,
  ],
] as const;

test("the installed lint engine rejects leaking effects and accepts owned handles", () => {
  for (const [index, [name, code]] of cases.entries()) {
    const imports = name === "unrelated API" ? "" : prefix;
    writeFileSync(join(directory, `${index}.tsx`), imports + code);
  }
  const result = Bun.spawnSync([vp, "lint", "--config", config, "--format", "json", directory], {
    cwd: resolve(import.meta.dir, ".."),
    stdout: "pipe",
    stderr: "pipe",
  });
  const output = new TextDecoder().decode(result.stdout);
  expect(result.exitCode, output + new TextDecoder().decode(result.stderr)).toBe(1);
  const diagnostics = JSON.parse(output).diagnostics as { filename: string; code: string }[];
  for (const [index, [name, , errors]] of cases.entries()) {
    expect(
      diagnostics.filter((d) => d.filename.endsWith(`/${index}.tsx`)),
      name,
    ).toHaveLength(errors);
  }
  expect(diagnostics.every((d) => d.code.includes("effect-interval-cleanup"))).toBe(true);
}, 30_000);

test("removing the existing cleanup from real direct and nested interval effects fails", () => {
  for (const [index, path] of [
    "src/agent-session/acpmux/EnvironmentPicker.tsx",
    // SubagentGroup.tsx's nested interval moved to the page clock (#28537, ui/pageClock.ts); the
    // run board's poll is a conditional interval cleared inside a block cleanup.
    "src/agent-session/acpmux/run-board/RunBoard.tsx",
  ].entries()) {
    const text = readFileSync(resolve(import.meta.dir, "..", path), "utf8");
    const mutation = text.replaceAll("clearInterval(", "forgetInterval(");
    expect(mutation).not.toBe(text);
    const file = join(directory, `mutation-${index}.tsx`);
    writeFileSync(file, mutation);
    const result = Bun.spawnSync([vp, "lint", "--config", config, "--format", "json", file], {
      cwd: resolve(import.meta.dir, ".."),
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(result.exitCode).toBe(1);
    const report = JSON.parse(new TextDecoder().decode(result.stdout));
    expect(report.diagnostics.some((d: { code: string }) => d.code.includes("effect-interval-cleanup"))).toBe(true);
  }
}, 30_000);
