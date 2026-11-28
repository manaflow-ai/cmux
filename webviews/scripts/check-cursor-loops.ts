// Every loop in the chat's client (direct.ts) and its row model says why it ends. Leo's NIGHTLY chat renderer sat at
// 100% CPU and 14 GB, every page in it frozen and unclosable: the span loop in `shedOlderHeld` stepped its cut back to
// `firstHeldFrom(events, from)`, which found the same cut again when no held record lay between, and spun. Leo,
// 2026-11-16: "the dream is infinite chats of infinite length with flat or no growth in cpu/memory/even disk".
// A `while`, `do ... while` or `for` with no condition (`for (;;)`), read from the TypeScript AST, fails unless its own line, or the comment lines just above it,
// say `ends: <reason>`: the cursor that moves each pass and where it stops (a binary search halving its range, an
// index falling to 0), the check that returns when a pass moved nothing, or the cap that ends it.
// Tests (*.test.*) are left out: a test that spins times out, it never holds a person's page.
// test/check-cursor-loops.test.ts runs it; `bun scripts/check-cursor-loops.ts` runs it alone.
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

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

/// A `//` or `///` comment that says why its loop ends.
const MARKER = /^\/\/\/?\s*ends:\s*\S/;

export type LoopFinding = { file: string; line: number; text: string };

/// A loop the rule reads, from the parsed source: a `while`, a `do ... while` (once, at its `do`) and a `for` with no
/// condition. A `while (` in a string, a template literal or a comment is no node, and a header split over lines is one.
function isCursorLoop(node: ts.Node): boolean {
  return ts.isWhileStatement(node) || ts.isDoStatement(node) || (ts.isForStatement(node) && !node.condition);
}

type LineComment = { start: number; text: string };

/// The `//` comments of a source by the 0-based line each starts on, read from the trivia around every token.
function lineComments(source: ts.SourceFile): Map<number, LineComment[]> {
  const text = source.text;
  const seen = new Set<number>();
  const byLine = new Map<number, LineComment[]>();
  const add = (ranges: ts.CommentRange[] | undefined) => {
    for (const range of ranges ?? []) {
      if (range.kind !== ts.SyntaxKind.SingleLineCommentTrivia || seen.has(range.pos)) continue;
      seen.add(range.pos);
      const line = source.getLineAndCharacterOfPosition(range.pos).line;
      const list = byLine.get(line) ?? [];
      list.push({ start: range.pos, text: text.slice(range.pos, range.end) });
      byLine.set(line, list);
    }
  };
  const visit = (node: ts.Node) => {
    add(ts.getLeadingCommentRanges(text, node.getFullStart()));
    add(ts.getTrailingCommentRanges(text, node.getEnd()));
    // getChildren holds the tokens too, so a comment after a `{` or before the file's end is read.
    for (const child of node.getChildren(source)) visit(child);
  };
  visit(source);
  return byLine;
}

/// The loops in one file's text that do not say why they end.
export function findUnprovedLoops(file: string, text: string): LoopFinding[] {
  const kind = file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, kind);
  const lines = text.split("\n");
  const comments = lineComments(source);
  const marked = (line: number) => (comments.get(line) ?? []).some((comment) => MARKER.test(comment.text));
  /// A line that holds only a `//` comment: its first non-blank character starts one.
  const commentOnly = (line: number) => {
    const raw = lines[line]!;
    const first = source.getPositionOfLineAndCharacter(line, 0) + raw.length - raw.trimStart().length;
    return (comments.get(line) ?? []).some((comment) => comment.start === first);
  };
  const findings: LoopFinding[] = [];
  const visit = (node: ts.Node) => {
    if (isCursorLoop(node)) {
      const line = source.getLineAndCharacterOfPosition(node.getStart(source)).line;
      let proved = marked(line);
      // ends: `above` falls by one each pass, to 0 at most
      for (let above = line - 1; !proved && above >= 0 && commentOnly(above); above -= 1) proved = marked(above);
      if (!proved) findings.push({ file, line: line + 1, text: lines[line]!.trim() });
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
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
