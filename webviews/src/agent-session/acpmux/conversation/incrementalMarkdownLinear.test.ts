import { describe, expect, test } from "bun:test";
import { IncrementalMarkdown, fenceLines, lastBlockBoundary } from "./incrementalMarkdown";
import { type MdBlock, parseMarkdown } from "./markdownModel";
import { safeTail } from "./safeTail";

// A streaming reply whose last block never closes (one long paragraph, fence, list or table)
// parsed that whole block again on every delta: 64 KiB in 64-character deltas read 33,587,200
// characters, 640 KiB read 3,355,770,880 (100x for 10x the text). The open block is now split
// where the text before parses the same alone, so each delta parses about what it appended.

/// What the parser drew before the split: the closed blocks as each boundary closed them, and the
/// text after the last boundary parsed whole (through safeTail while streaming).
class Reference {
  private closed: MdBlock[] = [];
  private closedEnd = 0;
  update(source: string, streaming: boolean, messageAt?: number): MdBlock[] {
    const boundary = lastBlockBoundary(source, this.closedEnd);
    if (boundary > this.closedEnd) {
      this.closed.push(...parseMarkdown(source.slice(this.closedEnd, boundary), { messageAt }));
      this.closedEnd = boundary;
    }
    const rest = source.slice(this.closedEnd);
    return [...this.closed, ...parseMarkdown(streaming ? safeTail(rest) : rest, { messageAt })];
  }
}

/// Streams `text` in `sizes` deltas, checking every frame (and the finished text) against the
/// reference; returns the characters parsed in all.
function stream(text: string, sizes: (index: number) => number, messageAt?: number): number {
  const parser = new IncrementalMarkdown();
  const reference = new Reference();
  let parsed = 0;
  let end = 0;
  for (let index = 0; end < text.length; index++) {
    end = Math.min(text.length, end + Math.max(1, sizes(index)));
    const prefix = text.slice(0, end);
    const drawn = parser.update(prefix, { streaming: true, messageAt });
    parsed += parser.lastParsedLength;
    const expected = reference.update(prefix, true, messageAt);
    if (JSON.stringify(drawn.map((entry) => entry.block)) !== JSON.stringify(expected)) {
      expect({ end, prefix, blocks: drawn.map((entry) => entry.block) }).toEqual({ end, prefix, blocks: expected });
    }
    expect(drawn.map((entry) => entry.key)).toEqual(expected.map((_, at) => String(at)));
    expect(parser.fenceOpen).toBe((fenceLines(prefix) & 1) === 1);
  }
  const done = parser.update(text, { streaming: false, messageAt });
  expect(done.map((entry) => entry.block)).toEqual(reference.update(text, false, messageAt));
  expect(done.map((entry) => entry.block)).toEqual(parseMarkdown(text, { messageAt }));
  return parsed;
}

/// A deterministic random source (mulberry32).
function random(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const WORDS = "the parser reads each line once and keeps what it drew so a long reply streams flat".split(" ");
const INLINE = [
  "**bold words**",
  "*italic*",
  "_under_",
  "`code span`",
  "``two `ticks``",
  "[a link](https://example.com/a)",
  "![img](data:image/png;base64,AAAA)",
  "$x^2$",
  "\\(a+b\\)",
  "$5",
  "at 3:22",
  "2026-11-19 14:05 UTC",
  "src/app.ts:12",
  "~/notes/plan.md",
  "repo#",
  "[^1]",
  "~~gone~~",
  "a | b",
  "\\*",
  "2*3",
  "snake_case",
  "**open",
  "`open",
  "[open",
];

function prose(next: () => number, words: number): string {
  const out: string[] = [];
  for (let index = 0; index < words; index++) {
    const roll = next();
    out.push(roll < 0.12 ? INLINE[Math.floor(next() * INLINE.length)]! : WORDS[Math.floor(next() * WORDS.length)]!);
  }
  return out.join(" ");
}

/// Mixed Markdown: paragraphs (one long line or wrapped), fences (closed, open, nested backtick
/// counts), lists (nested, numbered, blank-separated), tables, nested quotes, headings, rules and
/// display math, with blank lines or none between.
function document(seed: number, blocks: number): string {
  const next = random(seed);
  const pick = <T>(items: T[]) => items[Math.floor(next() * items.length)]!;
  const parts: string[] = [];
  for (let index = 0; index < blocks; index++) {
    const kind = Math.floor(next() * 12);
    if (kind <= 1) {
      const lines = 1 + Math.floor(next() * 4);
      parts.push(Array.from({ length: lines }, () => prose(next, 4 + Math.floor(next() * 60))).join("\n"));
    } else if (kind === 2) {
      const ticks = pick(["```", "```", "````"]);
      const body = Array.from({ length: 1 + Math.floor(next() * 12) }, () =>
        pick(["let x = 1;", "", "  indented()", "```", "`tick", "- not a list", "| a | b |", "$$", prose(next, 6)]),
      );
      parts.push(`${ticks}${pick(["ts", "", "sh"])}\n${body.join("\n")}${next() < 0.8 ? `\n${ticks}` : ""}`);
    } else if (kind === 3) {
      const ordered = next() < 0.4;
      const items = Array.from({ length: 1 + Math.floor(next() * 10) }, (_, at) => {
        const marker = ordered ? `${at + 1}.` : pick(["-", "*", "-"]);
        const nested = next() < 0.25 ? `\n   - ${prose(next, 3)}\n     more ${prose(next, 2)}` : "";
        const gap = next() < 0.2 ? "\n" : "";
        return `${marker} ${prose(next, 2 + Math.floor(next() * 12))}${nested}${gap}`;
      });
      parts.push(items.join("\n"));
    } else if (kind === 4) {
      const rows = Array.from(
        { length: 1 + Math.floor(next() * 10) },
        () => `| ${prose(next, 2)} | ${prose(next, 3)} |`,
      );
      parts.push([pick(["| A | B |", "A | B"]), pick(["|---|:--:|", "---|---"]), ...rows].join("\n"));
    } else if (kind === 5) {
      const lines = Array.from(
        { length: 1 + Math.floor(next() * 6) },
        () => pick(["> ", "> > ", ">"]) + pick([prose(next, 5), "- quoted item", "```", "", "> deeper"]),
      );
      parts.push(lines.join("\n"));
    } else if (kind === 6) parts.push(`${pick(["#", "##", "###"])} ${prose(next, 4)}`);
    else if (kind === 7) parts.push(pick(["---", "***", "- - -"]));
    else if (kind === 8) parts.push(pick(["$$\nE = mc^2\n$$", "\\[\na + b\n\\]", "$$x$$", "$$\nopen display"]));
    else parts.push(prose(next, 20 + Math.floor(next() * 200)));
  }
  return parts.map((part, at) => (at === 0 ? part : pick(["\n\n", "\n\n", "\n", "\n\n\n"]) + part)).join("");
}

describe("IncrementalMarkdown draws what a whole parse draws", () => {
  for (let seed = 1; seed <= 60; seed++) {
    test(`mixed Markdown, seed ${seed}`, () => {
      const next = random(seed * 7919);
      const text = document(seed, 6 + (seed % 10));
      const small = seed % 3 === 0;
      stream(
        text,
        () => (small ? 1 + Math.floor(next() * 4) : 1 + Math.floor(next() * 80)),
        seed % 2 ? Date.UTC(2026, 10, 19) : undefined,
      );
    });
  }

  test("each kind of long open block, every prefix", { timeout: 60_000 }, () => {
    const next = random(42);
    const kinds = [
      `Intro.\n\n${prose(next, 400)}`,
      `\`\`\`ts\n${Array.from({ length: 60 }, (_, at) => `line ${at} ${prose(next, 4)}`).join("\n")}`,
      `\`\`\`\n${"x".repeat(900)} ${prose(next, 30)}`,
      Array.from({ length: 50 }, (_, at) => `${at % 7 === 3 ? "\n" : ""}- ${prose(next, 6)}`).join("\n"),
      Array.from({ length: 30 }, (_, at) => `${at + 1}. ${prose(next, 5)}\n   - inner ${prose(next, 2)}`).join("\n"),
      `| A | B |\n|---|---|\n${Array.from({ length: 40 }, () => `| ${prose(next, 2)} | ${prose(next, 2)} |`).join("\n")}`,
      `> ${prose(next, 30)}\n> > ${prose(next, 30)}\n> - item\n> ${prose(next, 30)}`,
      `${prose(next, 150)}\n${prose(next, 150)}\n${prose(next, 150)}`,
    ];
    for (const text of kinds) stream(text, () => 1);
  });
});

/// The characters parsed while `text` streams in 64-character deltas.
function parsedChars(text: string): number {
  const parser = new IncrementalMarkdown();
  let parsed = 0;
  for (let end = 64; end <= text.length; end += 64) {
    parser.update(text.slice(0, end), { streaming: true });
    parsed += parser.lastParsedLength;
  }
  return parsed;
}

const KIB = 1024;
const fill = (unit: string, size: number) => unit.repeat(Math.ceil(size / unit.length)).slice(0, size);

describe("streaming parse cost is linear in the reply", () => {
  const shapes: Record<string, (size: number) => string> = {
    // The finding's text: plain alphabetic, no newline or Markdown character.
    paragraph: (size) => fill("lorem ipsum dolor sit amet ", size),
    "wrapped paragraph": (size) => fill("lorem ipsum dolor sit amet consectetur\n", size),
    "open fence": (size) => `\`\`\`ts\n${fill("const value = compute(input);\n", size - 6)}`,
    "one-line fence": (size) => `\`\`\`\n${fill("abcdefgh", size - 4)}`,
    list: (size) => fill("- an item of a long list\n", size),
    table: (size) => `| a | b |\n|---|---|\n${fill("| cell one | cell two |\n", size - 20)}`,
  };
  for (const [name, shape] of Object.entries(shapes)) {
    test(`${name}: 10x the text parses about 10x the characters`, () => {
      const small = parsedChars(shape(64 * KIB));
      const large = parsedChars(shape(640 * KIB));
      console.log(
        `${name}: 64 KiB ${small.toLocaleString("en")} chars, 640 KiB ${large.toLocaleString("en")} chars (${(large / small).toFixed(2)}x)`,
      );
      expect(large / small).toBeLessThan(12);
      expect(large / small).toBeGreaterThan(8);
      // Each delta parses a bounded amount beyond what it appended.
      expect(large).toBeLessThan(640 * KIB * 8);
    }, 60_000);
  }
});
