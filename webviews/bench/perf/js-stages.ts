/// <reference types="bun" />
// JS-side stage costs for one patch file, off the page: the viewer's own streamPatch + Pierre
// processFile (the "JS parse" stage), then Shiki (oniguruma WASM, the engine the viewer's
// workers use) over every changed file's lines in one thread (the "full highlighting" stage).
// Bench only. Usage: bun bench/perf/js-stages.ts <patch> [--no-highlight] [--highlight-files N]
import { parsePatchFiles, processFile } from "@pierre/diffs";
import { readFileSync, statSync } from "node:fs";
import { createHighlighter } from "shiki";
import { createOnigurumaEngine } from "shiki/engine/oniguruma";
import { createDiffViewerLabelResolver } from "../../src/labels";
import { streamPatch, type DiffItem } from "../../src/diff-stream";

const patchPath = process.argv[2];
const noHighlight = process.argv.includes("--no-highlight");
const highlightLimitIndex = process.argv.indexOf("--highlight-files");
const highlightLimit = highlightLimitIndex > 0 ? Number(process.argv[highlightLimitIndex + 1]) : Infinity;
const bytes = statSync(patchPath).size;
const readStart = performance.now();
const patch = readFileSync(patchPath);
const readMs = performance.now() - readStart;

Object.assign(globalThis, {
  document: { visibilityState: "hidden", hasFocus: () => false },
  window: globalThis,
  fetch: async () => new Response(patch, { status: 200, headers: { "Content-Type": "text/x-diff" } }),
});

const heapBefore = process.memoryUsage().heapUsed;
const items: DiffItem[] = [];
let firstBatchMs = 0;
const parseStart = performance.now();
await streamPatch({
  getCollapsed: () => false,
  initialFileTreeRowCount: 32,
  label: createDiffViewerLabelResolver(undefined),
  onBatch: (batch) => {
    if (firstBatchMs === 0) firstBatchMs = performance.now() - parseStart;
    items.push(...batch);
  },
  onComplete: () => {},
  onMetrics: () => {},
  onRename: () => {},
  onTreeSource: () => {},
  parsePatchFiles,
  patchURL: "bench://patch",
  processFile,
});
const parseMs = performance.now() - parseStart;
Bun.gc(true);
const heapAfterParseMB = (process.memoryUsage().heapUsed - heapBefore) / 1048576;

const result: Record<string, unknown> = {
  patch: patchPath,
  patchMB: +(bytes / 1048576).toFixed(1),
  files: items.length,
  readMs: +readMs.toFixed(1),
  parseMs: +parseMs.toFixed(1),
  firstBatchMs: +firstBatchMs.toFixed(1),
  heapAfterParseMB: +heapAfterParseMB.toFixed(1),
};

if (!noHighlight) {
  const langFor = (name: string) => {
    const ext = name.slice(name.lastIndexOf(".") + 1);
    return (
      {
        ts: "typescript",
        tsx: "tsx",
        rs: "rust",
        py: "python",
        go: "go",
        swift: "swift",
        json: "json",
        md: "markdown",
        css: "css",
        sh: "shellscript",
        js: "javascript",
      } as Record<string, string>
    )[ext];
  };
  const langs = [
    "typescript",
    "tsx",
    "rust",
    "python",
    "go",
    "swift",
    "json",
    "markdown",
    "css",
    "shellscript",
    "javascript",
  ];
  const initStart = performance.now();
  const highlighter = await createHighlighter({
    themes: ["github-dark"],
    langs,
    engine: createOnigurumaEngine(import("shiki/wasm")),
  });
  const initMs = performance.now() - initStart;
  let lines = 0;
  let tokens = 0;
  let files = 0;
  const perLang: Record<string, { ms: number; lines: number }> = {};
  const hlStart = performance.now();
  for (const item of items) {
    if (files >= highlightLimit) break;
    const diff = item.fileDiff;
    const lang = langFor(diff?.name ?? "");
    if (!lang) continue;
    files += 1;
    for (const side of [diff.deletionLines, diff.additionLines] as string[][]) {
      if (!side?.length) continue;
      const start = performance.now();
      // Pierre tokenizes each side as one document (lines keep their newline).
      const text = side[0]?.endsWith("\n") ? side.join("") : side.join("\n");
      const result = highlighter.codeToTokens(text, { lang: lang as any, theme: "github-dark", tokenizeMaxLineLength: 1000 });
      const ms = performance.now() - start;
      lines += side.length;
      for (const line of result.tokens) tokens += line.length;
      perLang[lang] ??= { ms: 0, lines: 0 };
      perLang[lang].ms += ms;
      perLang[lang].lines += side.length;
    }
  }
  const hlMs = performance.now() - hlStart;
  Object.assign(result, {
    shikiInitMs: +initMs.toFixed(1),
    highlightFiles: files,
    highlightLines: lines,
    highlightTokens: tokens,
    highlightMs: +hlMs.toFixed(1),
    linesPerSec: Math.round(lines / (hlMs / 1000)),
    perLang: Object.fromEntries(
      Object.entries(perLang).map(([lang, value]) => [lang, Math.round(value.lines / (value.ms / 1000))]),
    ),
  });
}
console.log(JSON.stringify(result));
