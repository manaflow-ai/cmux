// l10n-allow-file: test fixture prompts, not shipped UI.
// A sent message is one continuous text body (ask-14d16a6247; Leo, 2026-11-07, of his dictated
// message pasted in three parts and drawn as three "Pasted text" cards: "Like just don't separate
// these out. And, like, I thought we said, you know, remove these inner bubbles, inner, inner
// cards."). Pasted text is part of the message: no card, no per-paste chevron, no gap past normal
// paragraph spacing, and one fold at the bubble's level. It holds for a transcript that already
// recorded its pastes (`user_message.pasted` ranges, the legacy shape) and for one whose pastes the
// composer placed in its text (`inlineParts`), so it is a render-side fix.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  NodeFilter: dom.window.NodeFilter,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
type Row = Parameters<typeof UserBubble>[0]["row"];

// Leo's message: one dictation pasted in three parts (1.6K, 503 and 218 characters).
const sentence = (word: string) =>
  `So the ${word} thing I keep noticing is that the transcript separates what I said into pieces, and it should not. `;
const part = (word: string, chars: number) =>
  sentence(word)
    .repeat(Math.ceil(chars / sentence(word).length))
    .slice(0, chars)
    .trim();
const FIRST = part("first", 1600);
const SECOND = part("second", 503);
const THIRD = part("third", 218);

/// Every element that draws a paste apart from the message's text: a card, its label button and
/// chevron, or a block of its own.
const INNER = ".cv-user__paste-block, .cv-user__paste-card, .cv-user__paste, .cv-user__paste-chevron, .cv-user__pasted";

function render(row: Row) {
  resetTranscriptDisclosure();
  act(() => root.render(<UserBubble row={row} text={row.text ?? ""} />));
  return host.querySelector(".cv-user__bubble")!;
}

/// The bubble's text bodies: each run of the message's words drawn as one text.
const bodies = (bubble: Element) => [...bubble.querySelectorAll(".cv-user__typed, .cv-user__markdown")];

test("a sent message recorded with three pasted parts draws as one body with one fold", () => {
  const text = [FIRST, SECOND, THIRD].join("\n");
  const pasted = [
    { start: 0, end: FIRST.length },
    { start: FIRST.length + 1, end: FIRST.length + 1 + SECOND.length },
    { start: FIRST.length + SECOND.length + 2, end: text.length },
  ];
  const bubble = render({ id: "legacy", version: 1, at: Date.now(), kind: "user", text, pasted });
  expect(bubble.querySelectorAll(INNER).length).toBe(0);
  const drawn = bodies(bubble);
  expect(drawn.length).toBe(1);
  expect(drawn[0]!.textContent).toContain(FIRST);
  expect(drawn[0]!.textContent).toContain(SECOND);
  expect(drawn[0]!.textContent).toContain(THIRD);
  // One fold, at the bubble's level: a long message has one Show more and nothing else to open.
  expect(bubble.querySelectorAll(".cv-user__more").length).toBe(1);
  expect(bubble.querySelectorAll("[aria-expanded]").length).toBe(1);
});

test("a sent message whose three pastes the composer placed reads as the draft did, in one body", () => {
  const paste = (text: string) => ({ kind: "pasted", placed: true, text });
  const inlineParts = [
    paste(FIRST),
    { kind: "text", text: " " },
    paste(SECOND),
    { kind: "text", text: " " },
    paste(THIRD),
  ];
  const text = [FIRST, " ", SECOND, " ", THIRD].join("\n");
  const bubble = render({ id: "placed", version: 1, at: Date.now(), kind: "user", text, inlineParts } as Row);
  expect(bubble.querySelectorAll(INNER).length).toBe(0);
  const drawn = bodies(bubble);
  expect(drawn.length).toBe(1);
  // As typed: the words between the pastes are the draft's own, and no line is added between them.
  expect(drawn[0]!.textContent).toBe(`${FIRST} ${SECOND} ${THIRD}`);
  expect(bubble.querySelectorAll(".cv-user__more").length).toBe(1);
});

test("Find does not count a text file's body, which draws only as its chip", async () => {
  // A placed text file's body went as a text block, so it is in the recorded text; the bubble draws
  // only its chip. Counted, a match there opened the fold to nothing Find could show or highlight.
  const { findMatches } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const body = "notes.txt\n```\nzanzibar rollout plan\n```";
  const inlineParts = [
    { kind: "text", text: "See the notes" },
    { kind: "file", placed: true, name: "notes.txt", mimeType: "text/plain", size: 22, text: body },
  ];
  const row = {
    id: "file-row",
    version: 1,
    at: Date.now(),
    kind: "user",
    text: `See the notes\n${body}`,
    inlineParts,
  } as Row;
  expect(findMatches([row], "zanzibar").length).toBe(0);
  expect(findMatches([row], "notes").length).toBeGreaterThan(0);
  const bubble = render(row);
  expect(bubble.querySelector(".acpmux-file-chip")).not.toBeNull();
  expect(bubble.querySelector(".cv-user__more")).toBeNull();
});

test("a short message with a paste draws no fold and no card", () => {
  const typed = "Can you look at this?";
  const text = `${typed}\n${THIRD}`;
  const bubble = render({
    id: "short",
    version: 1,
    at: Date.now(),
    kind: "user",
    text,
    pasted: [{ start: typed.length + 1, end: text.length }],
  });
  expect(bubble.querySelectorAll(INNER).length).toBe(0);
  expect(bodies(bubble).length).toBe(1);
  expect(bodies(bubble)[0]!.textContent).toBe(text);
  expect(bubble.querySelectorAll(".cv-user__more").length).toBe(0);
});

afterAll(() => {
  act(() => root.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
