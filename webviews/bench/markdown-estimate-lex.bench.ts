// l10n-allow-file: bench fixture replies, not shipped UI.
// What lexing a streaming reply's open block costs the transcript's height estimate (model.ts
// markdownBlocks, which lexIncrementally calls on every token for the text after the last block
// boundary), against marked's lexer as it was called before (Leo, 2026-11-25: "idk we've measured
// tons of shit already you guys should all be trying to optimize the fuck outta things"). Under
// JavaScriptCore (WKWebView, and bun here) marked's setext-heading regex (`lheading`), tried on every
// paragraph and nearly always failing, costs ~0.07 ms per 1,000 characters up to about 10,000 and then
// ~6 ms per 1,000 (its JIT gives up past a backtracking limit): a 12,000-character open paragraph cost
// ~80 ms a token. markdownBlocks asks the rule only of text that may hold a setext underline.
// Shapes, each lexed at every size (characters of the open block):
//   paragraph  one paragraph, no newline (a long explanation streaming)
//   lines      one paragraph of short lines (`breaks: true` text, a log or an address block)
//   list       a list of one-line items (one block until a blank line ends it)
//   setext     a paragraph under a `---` underline (the rule matching: must cost the same)
// Prints the median ms per lex for both and their ratio, and PERF_ROW lines. Then STREAM: a reply whose
// one open paragraph grows to 16,000 characters, 40 characters a token, each token through the whole
// estimate (layoutConversation on a new row object, as VirtualTranscript calls it): ms per token, p50
// and p95, over the tokens past 10,000 characters. Run it on the base commit for its before.
//   bun bench/markdown-estimate-lex.bench.ts [--sizes 2000,8000,12000,16000,32000] [--rounds 15]
/// <reference types="bun" />
import { lexer } from "marked";
import {
  layoutConversation,
  markdownBlocks,
  type AcpmuxRow,
  type ConversationLayout,
  type PreparedRow,
  type RowHeights,
} from "../src/agent-session/acpmux/model";
import { perfRow, TARGET_MS } from "./perfRow";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const SIZES = (flag("--sizes") ?? "2000,8000,12000,16000,32000").split(",").map(Number);
const ROUNDS = Number(flag("--rounds") ?? 15);

const fill = (size: number, piece: (index: number) => string) => {
  let text = "";
  for (let index = 0; text.length < size; index += 1) text += piece(index);
  return text.slice(0, size);
};
const shapes: Record<string, (size: number) => string> = {
  paragraph: (size) => fill(size, (i) => `the **review pass** on lane ${i} found \`one\` thing, `),
  lines: (size) => fill(size, (i) => `lane ${i}: green on the head\n`),
  list: (size) => fill(size, (i) => `- lane ${i} is green; the review pass is next\n`),
  setext: (size) => `${fill(size, (i) => `heading words ${i} `)}\n---\n`,
};
const before = (source: string) => lexer(source, { gfm: true, breaks: true }).filter((t) => t.type !== "space");

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
const time = (run: () => unknown) => {
  const start = performance.now();
  run();
  return performance.now() - start;
};

for (const [shape, make] of Object.entries(shapes)) {
  for (const size of SIZES) {
    const source = make(size);
    if (JSON.stringify(before(source)) !== JSON.stringify(markdownBlocks(source)))
      throw new Error(`${shape} ${size}: tokens differ`);
    const a: number[] = [];
    const b: number[] = [];
    for (let round = 0; round < ROUNDS; round += 1) {
      // Alternate which goes first so neither always runs on a warmer heap.
      if (round % 2) {
        a.push(time(() => before(source)));
        b.push(time(() => markdownBlocks(source)));
      } else {
        b.push(time(() => markdownBlocks(source)));
        a.push(time(() => before(source)));
      }
    }
    const was = median(a);
    const now = median(b);
    console.log(
      `${shape.padEnd(9)} ${String(size).padStart(6)} chars: before ${was.toFixed(3)} ms, after ${now.toFixed(3)} ms (${(was / now).toFixed(1)}x)`,
    );
    perfRow({ name: `markdown_estimate_lex.${shape}.${size}.before_ms`, p50: was, p95: Math.max(...a), unit: "ms" });
    perfRow({ name: `markdown_estimate_lex.${shape}.${size}.after_ms`, p50: now, p95: Math.max(...b), unit: "ms" });
  }
}

// The streaming reply through the transcript's estimate, as a long chat's last row.
const STREAM_TO = Number(flag("--stream-to") ?? 16_000);
{
  const prompt: AcpmuxRow = { id: "prompt", version: 1, at: 1, kind: "user", text: "Explain the whole incident." };
  let reply: AcpmuxRow = { id: "reply", version: 1, at: 2, kind: "assistant", text: "" };
  const cache = new Map<string, PreparedRow>();
  const known: RowHeights = new WeakMap();
  let rows: AcpmuxRow[] = [prompt, reply];
  let layout: ConversationLayout = layoutConversation(rows, 720, cache, undefined, known);
  const late: number[] = [];
  const words = shapes.paragraph!(STREAM_TO + 40);
  for (let length = 40; length <= STREAM_TO; length += 40) {
    reply = { ...reply, version: reply.version + 1, text: words.slice(0, length) };
    const next = [prompt, reply];
    const start = performance.now();
    layout = layoutConversation(next, 720, cache, undefined, known, { rows, layout });
    const took = performance.now() - start;
    if (length > 10_000) late.push(took);
    rows = next;
  }
  late.sort((a, b) => a - b);
  const p50 = late[Math.floor(late.length / 2)]!;
  const p95 = late[Math.min(late.length - 1, Math.floor(late.length * 0.95))]!;
  console.log(
    `stream    to ${STREAM_TO} chars, 40 a token: ${p50.toFixed(3)} ms p50, ${p95.toFixed(3)} ms p95 per token past 10,000 (${late.length} tokens)`,
  );
  perfRow({ name: "markdown_estimate_lex.stream.token_ms", p50, p95, target: TARGET_MS.frameWork });
}
