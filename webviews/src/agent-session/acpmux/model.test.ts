import { describe, expect, test } from "bun:test";
import type { Tokens } from "marked";
import {
  diffRows,
  editedCardHeight,
  layoutConversation,
  markdownBlocks,
  measuredText,
  paneHeader,
  visibleLayoutRange,
  visibleRowRange,
  type AcpmuxRow,
  type AcpmuxSnapshot,
  type ConversationLayout,
  type PreparedRow,
} from "./model";

const row = (id: string, version: number): AcpmuxRow => ({ id, version, at: 0, kind: "assistant", text: id });

describe("acpmux row snapshots", () => {
  test("only changed content versions update", () => {
    const before = new Map([
      ["a", row("a", 1)],
      ["b", row("b", 1)],
    ]);
    expect(diffRows(before, [row("a", 1), row("b", 2), row("c", 1)])).toEqual({
      added: [row("c", 1)],
      updated: [row("b", 2)],
      removed: [],
    });
  });

  test("virtualizer keeps a bounded overscan window", () => {
    expect(visibleRowRange(5000, 12000, 720)).toEqual({ first: 117, last: 141 });
  });

  test("binary-searches exact typed-array tops", () => {
    const layout: ConversationLayout = {
      tops: new Float64Array([0, 30, 90, 150]),
      heights: new Float64Array([30, 60, 60, 40]),
      totalHeight: 190,
    };
    expect(visibleLayoutRange(layout, 91, 40, 0)).toEqual({ first: 2, last: 3 });
    expect(visibleLayoutRange(layout, 0, 20, 1)).toEqual({ first: 0, last: 2 });
  });
});

/// A user bubble (9px padding top and bottom, styles.css) rendered taller than its row, so the next
/// row's text ran under it.
test("a one-line user row leaves room for its bubble and the gap below it", () => {
  const user = {
    id: "u",
    version: 1,
    at: 0,
    kind: "user",
    text: "Question 1: how should the transcript handle item 1?",
  };
  const { heights } = layoutConversation([user], 760);
  const bubblePadding = 18;
  const line = 20;
  const gap = 16;
  expect(heights[0]).toBeGreaterThanOrEqual(bubblePadding + line + gap);
});

/// Every row below measures one row through the estimator and compares it with what the CSS draws.
const height = (kind: string, text: string, width: number) =>
  layoutConversation([{ id: `${kind}-${width}-${text}`, version: 1, at: 0, kind, text }], width).heights[0]!;
const paragraph = "word ".repeat(120).trim();

/// The bubble is at most 78% of the row and its 12px side padding sits inside that, so its text
/// wraps at 0.78 * width - 24, well short of the row's own width.
test("a long user message wraps at the bubble's width", () => {
  expect(height("user", paragraph, 724)).toBeGreaterThanOrEqual(height("assistant", paragraph, 0.78 * 724 - 24) + 18);
});

/// A single newline starts a new block when the next line is a heading or a list, and blocks are
/// 8px apart (styles.css), so splitting on blank lines alone missed the gap and the extra line.
test("a heading or a list after a single newline is its own block", () => {
  const line = 20;
  const gap = 8;
  const rowGap = 16;
  expect(height("assistant", "## Title\nSome text", 724)).toBeGreaterThanOrEqual(rowGap + 2 * line + gap);
  expect(height("assistant", "Intro:\n- one\n- two", 724)).toBeGreaterThanOrEqual(rowGap + 3 * line + gap);
});

/// A nested list's items are lines of their own, indented a second 40px.
test("a nested list measures each of its items", () => {
  const line = 20;
  const flat = height("assistant", "- order:", 724);
  expect(height("assistant", "- order:\n  - one\n  - two\n  - three", 724)).toBeGreaterThanOrEqual(flat + 3 * line);
  expect(height("assistant", `- order:\n  - ${paragraph}`, 724)).toBeGreaterThanOrEqual(
    flat + height("assistant", paragraph, 724 - 80) - 16,
  );
});

/// List items are indented 40px (the browser's list padding), so their text wraps sooner.
test("a list item wraps at the list's indented width", () => {
  expect(height("assistant", `- ${paragraph}`, 724)).toBeGreaterThanOrEqual(height("assistant", paragraph, 724 - 28));
});

/// The estimator measures what the page draws. Inline code draws in 12px monospace, no wider than the
/// prose font's digits, and a task item draws its checkbox's source text.
test("a block is measured as the text it renders", () => {
  const [code] = markdownBlocks("Call `fill()` now") as Tokens.Paragraph[];
  expect(measuredText(code!.tokens, code!.text)).toBe("Call 000000 now");
  const [list] = markdownBlocks("- [ ] ship it") as Tokens.List[];
  expect(measuredText(list!.items[0]!.tokens, list!.items[0]!.text)).toBe("[ ] ship it");
});

/// A monospace space is a full cell, wider than the prose font's space; and a link the page won't
/// open draws its label's source, not the parsed label.
test("code spaces and unopenable links are measured as drawn", () => {
  const measured = (source: string) => {
    const [block] = markdownBlocks(source) as Tokens.Paragraph[];
    return measuredText(block!.tokens, block!.text);
  };
  expect(measured("Run `a b` now")).toBe("Run 00 0 now");
  expect(measured("[**b**](mailto:x@y)")).toBe("**b**");
  expect(measured("[**b**](https://example.com)")).toBe("b");
});

describe("acpmux pane header", () => {
  const snapshot = (patch: Partial<AcpmuxSnapshot>): AcpmuxSnapshot => ({
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "connected",
    isWorking: false,
    queue: [],
    catalog: [],
    canLoadOlder: false,
    ...patch,
  });
  /// A real acpmux daemon names harnesses by id only, so the header read "codex".
  test("names a known agent when the catalog has only its id", () => {
    const header = (harness: string, catalog: AcpmuxSnapshot["catalog"] = []) =>
      paneHeader(snapshot({ summary: { sessionId: "s", harness }, catalog })).title;
    expect(header("codex")).toBe("Codex");
    expect(header("codex", [{ id: "codex", name: "codex", models: [] }])).toBe("Codex");
    expect(header("claude")).toBe("Claude Code");
    expect(header("claude-sr", [{ id: "claude-sr", name: "claude-sr", models: [] }])).toBe("Claude Code");
    expect(header("gemini")).toBe("Gemini CLI");
    expect(header("opencode")).toBe("OpenCode");
    expect(header("my-agent")).toBe("My Agent");
    expect(header("codex", [{ id: "codex", name: "Codex (team)", models: [] }])).toBe("Codex (team)");
  });
  const prompt = "Run total.py and tell me what it prints";
  /// The title repeated the session's first prompt, which the picker and the transcript already show,
  /// and the status showed the client's last event ("session changed", "tool_call").
  test("names the agent rather than repeating the prompt, and shows only a status a reader acts on", () => {
    const base = {
      summary: { sessionId: "s", title: prompt, harness: "codex" },
      catalog: [{ id: "codex", name: "Codex", models: [] }],
    };
    expect(paneHeader(snapshot({ ...base, connection: "session changed" }))).toEqual({ title: "Codex", status: "" });
    expect(paneHeader(snapshot({ ...base, connection: "tool_call", isWorking: true }))).toEqual({
      title: "Codex",
      status: "Working",
    });
    expect(paneHeader(snapshot({ ...base, connection: "disconnected" }))).toEqual({
      title: "Codex",
      status: "Reconnecting",
    });
    expect(paneHeader(snapshot({ connection: "mock" }))).toEqual({ title: "Agent Chat", status: "Mock" });
  });

  /// While the daemon is down the pane retries, setting "connecting" or "connecting: <error>"; a turn
  /// that was running when the connection dropped never ends, so connection trouble wins over Working.
  test("shows connection trouble while retrying, even during a turn", () => {
    expect(paneHeader(snapshot({ connection: "connecting" })).status).toBe("Connecting");
    expect(paneHeader(snapshot({ connection: "connecting: Error: refused" })).status).toBe("Connecting");
    expect(paneHeader(snapshot({ connection: "disconnected", isWorking: true })).status).toBe("Reconnecting");
  });
});

describe("turn row estimates", () => {
  const tool = (id: string, kind: string) => ({
    kind: "tool",
    text: id,
    tool: { id, title: id, kind, status: "completed" },
  });
  const estimate = (row: AcpmuxRow) => layoutConversation([row], 720).heights[0]!;
  test("the fold line and tool rows estimate their drawn heights", () => {
    expect(estimate({ id: "worked-u", version: 1, at: 0, kind: "worked" })).toBe(35);
    expect(
      estimate({
        id: "t",
        version: 1,
        at: 0,
        kind: "activity",
        items: [1, 2, 3, 4, 5].map((n) => tool(`r${n}`, "read")),
      }),
    ).toBe(140);
    // In an ended turn's open fold, the same run is one "Read files" line (conversation/toolRunSummary.ts).
    expect(
      estimate({
        id: "t",
        version: 1,
        at: 0,
        kind: "activity",
        settled: true,
        items: [1, 2, 3, 4, 5].map((n) => tool(`r${n}`, "read")),
      }),
    ).toBe(36);
  });
  test("an edit copied into an open fold estimates as tool rows, not the edited-files card", () => {
    const items = [tool("e1", "edit"), tool("e2", "edit")];
    // Inside the fold the two edits are one "Edited files" line.
    expect(estimate({ id: "e:fold", version: 1, at: 0, kind: "activity", settled: true, items })).toBe(36);
    // Outside the fold it is the edited-files card: two diffless files listed under its head.
    expect(estimate({ id: "e", version: 1, at: 0, kind: "activity", items })).toBe(14 + editedCardHeight(0, 2));
  });
});

/// R104 (hq-48's audit): the estimate re-lexed a streaming row's whole text on every delta,
/// quadratic over a turn. Only the text after the last safe block boundary is lexed again.
describe("streaming row estimate", () => {
  const reply =
    "# Plan\n\nFirst paragraph with `code` and **bold** words that wrap over a line or two in a pane.\n\n" +
    "- one\n- two\n\n- three after a blank\n\n```ts\nconst a = 1;\n\nconst b = 2;\n```\n\n" +
    "| a | b |\n| --- | --- |\n| 1 | 2 |\n\nClosing words.\n";

  test("every streamed prefix estimates exactly like a row estimated from scratch", () => {
    const cache = new Map<string, PreparedRow>();
    for (let length = 1; length <= reply.length; length += 3) {
      const row: AcpmuxRow = {
        id: "r",
        version: length,
        at: 1,
        kind: "assistant",
        text: reply.slice(0, length),
        streaming: true,
      };
      const streamed = layoutConversation([row], 600, cache).heights[0];
      const fresh = layoutConversation([row], 600, new Map()).heights[0];
      expect({ length, height: streamed }).toEqual({ length, height: fresh });
    }
  });

  test("a delta lexes the tail, not the whole reply", () => {
    const cache = new Map<string, PreparedRow>();
    const long = "A paragraph of words that the estimator measures.\n\n".repeat(300);
    const row = (text: string, version: number): AcpmuxRow => ({ id: "r", version, at: 1, kind: "assistant", text });
    layoutConversation([row(long + "tail", 1)], 600, cache);
    layoutConversation([row(long + "tail grows", 2)], 600, cache);
    expect(cache.get("r")!.lexedLength).toBeLessThan(200);
  });
});
