// Every loop in the chat's client (direct.ts) and its row model says why it ends. Leo's NIGHTLY chat renderer sat at
// 100% CPU and 14 GB, every page in it frozen and unclosable: the span loop in `shedOlderHeld` stepped its cut back to
// `firstHeldFrom(events, from)`, which found the same cut again when no held record lay between, and spun. Leo,
// 2026-11-16: "the dream is infinite chats of infinite length with flat or no growth in cpu/memory/even disk".
// A `while (`, `do {` or `for (;;)` in these files fails unless its own line, or the comment lines just above it,
// say `ends: <reason>`: the cursor that moves each pass and where it stops (a binary search halving its range, an
// index falling to 0), the check that returns when a pass moved nothing, or the cap that ends it.
// Tests (*.test.*) are left out: a test that spins times out, it never holds a person's page.
// test/check-cursor-loops.test.ts runs it; `bun scripts/check-cursor-loops.ts` runs it alone.
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../src");
const ACPMUX = "agent-session/acpmux";
/// The files the rule reads, under src/: single files, and directories read whole.
export const LOOP_FILES = [
  `${ACPMUX}/direct.ts`,
  `${ACPMUX}/placedHeightIndex.ts`,
  `${ACPMUX}/tailCache.ts`,
  `${ACPMUX}/conversation/turns.ts`,
];
export const LOOP_DIRS = [`${ACPMUX}/rows`];

const LOOP = /(?<![\w$.])(?:while\s*\(|do\s*\{|for\s*\(\s*;\s*;\s*\))/;
/// A do-while's tail (`} while (x);`): its `do {` is the loop, already read.
const DO_TAIL = /^\s*\}\s*while\s*\(/;
const MARKER = /\/\/\/?\s*ends:\s*\S/;
const COMMENT_LINE = /^\s*\/\//;

export type LoopFinding = { file: string; line: number; text: string };

/// The loops in one file's text that do not say why they end.
export function findUnprovedLoops(file: string, text: string): LoopFinding[] {
  const lines = text.split("\n");
  const findings: LoopFinding[] = [];
  let inBlock = false;
  for (let index = 0; index < lines.length; index += 1) {
    const raw = lines[index]!;
    // Block comments and JSDoc lines name loops in prose; only code is read.
    let code = raw;
    if (inBlock) {
      const close = code.indexOf("*/");
      if (close < 0) continue;
      inBlock = false;
      code = code.slice(close + 2);
    }
    const open = code.indexOf("/*");
    if (open >= 0 && code.indexOf("*/", open + 2) < 0) {
      inBlock = true;
      code = code.slice(0, open);
    }
    code = code.replace(/\/\*.*?\*\//g, "").replace(/\/\/.*$/, "");
    if (!LOOP.test(code) || DO_TAIL.test(code)) continue;
    if (MARKER.test(raw)) continue;
    let marked = false;
    for (let above = index - 1; above >= 0 && COMMENT_LINE.test(lines[above]!); above -= 1)
      if (MARKER.test(lines[above]!)) {
        marked = true;
        break;
      }
    if (marked) continue;
    findings.push({ file, line: index + 1, text: raw.trim() });
  }
  return findings;
}

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    return /\.tsx?$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name) ? [path] : [];
  });
}

/// Every loop in the rule's files that does not say why it ends.
export function findAllUnprovedLoops(srcDir: string = SRC): LoopFinding[] {
  const paths = [
    ...LOOP_FILES.map((file) => join(srcDir, file)),
    ...LOOP_DIRS.flatMap((dir) => sourceFiles(join(srcDir, dir))),
  ];
  return paths.flatMap((path) => findUnprovedLoops(relative(srcDir, path), readFileSync(path, "utf8")));
}

if (import.meta.main) {
  const found = findAllUnprovedLoops();
  for (const f of found)
    console.error(
      `cursor loop: ${f.file}:${f.line}: ${f.text} ` +
        "(say why it ends in a `// ends: <reason>` line above it: the cursor that moves each pass, a check that " +
        "returns when a pass moved nothing, or a cap)",
    );
  if (found.length) process.exitCode = 1;
  else console.log("Cursor loops checked: each says why it ends.");
}
