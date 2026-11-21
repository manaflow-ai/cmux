// Design mode (plans/cmux-next/design-mode-DESIGN.md): a pick in a browser pane reaches the agent
// chat as the host's `designSelection` event, and the composer holds it as ONE chip (David Beyer,
// 2026-11-20: several picks in a row must not get visually messy): its number and comment over the
// element, the element's details as its text and its screenshot crop riding inside it, both going
// with the next message. Picking or editing the same element again replaces its chip (same id).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
  });
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

const card = {
  id: "design-abc",
  name: "1 · Make this blue",
  text: [
    "Design mode highlight from the cmux browser.",
    "Pick: 1",
    "Comment: Make this blue",
    "Page: https://example.com/pricing",
    "Element: <button>",
    "Selector: #buy",
    "Text: Buy now",
  ].join("\n"),
  image: { mimeType: "image/png", data: "iVBORw0KGgo=" },
};

test("a pick is one chip that carries its crop", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const chips = designSelectionChips(card);
  expect(chips.map((chip) => [chip.id, chip.kind, chip.name])).toEqual([["design-abc", "text", "1 · Make this blue"]]);
  expect(chips[0]?.text).toBe(card.text);
  expect(chips[0]?.shot).toEqual({ mimeType: "image/png", data: "iVBORw0KGgo=" });
});

test("a pick without a crop is one chip with none; a bad value is none", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  expect(designSelectionChips({ ...card, image: undefined }).map((chip) => [chip.kind, chip.shot])).toEqual([
    ["text", undefined],
  ]);
  expect(designSelectionChips({ id: "x", name: "n" })).toEqual([]);
  expect(designSelectionChips(null)).toEqual([]);
  expect(designSelectionChips({ ...card, image: { mimeType: "text/html", data: "PGI+" } }).map((c) => c.shot)).toEqual([
    undefined,
  ]);
});

test("a sent pick goes as its text, then its crop as an image", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const { promptBlocks } = await import("../src/agent-session/acpmux/attachments");
  const blocks = promptBlocks("fix these", designSelectionChips(card));
  expect(blocks.map((block) => block.type)).toEqual(["text", "image"]);
  const text = (blocks[0] as { text: string }).text;
  expect(text.startsWith("fix these")).toBe(true);
  expect(text).toContain("Comment: Make this blue");
  expect(blocks[1]).toMatchObject({ type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" });
});

test("the host's designSelection event reaches the page bridge", async () => {
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const got: unknown[] = [];
  (dom.window as unknown as { cmuxAcpmuxBridge: unknown }).cmuxAcpmuxBridge = {
    designSelection: (value: unknown) => got.push(value),
  };
  applyHostEvent({ kind: "designSelection", value: card });
  expect(got).toEqual([card]);
});

test("a removed pick names its chip (and an older draft's crop chip); a card is no removal", async () => {
  const { designSelectionRemovals } = await import("../src/agent-session/acpmux/designSelection");
  expect(designSelectionRemovals({ removed: "design-abc" })).toEqual(["design-abc", "design-abc-shot"]);
  expect(designSelectionRemovals(card)).toEqual([]);
  expect(designSelectionRemovals({ removed: "" })).toEqual([]);
  expect(designSelectionRemovals(null)).toEqual([]);
});

test("picks that leave the composer (removed or sent) are named for the page, others are not", async () => {
  const { releasedPicks } = await import("../src/agent-session/acpmux/designSelection");
  const pick = (id: string) => ({ id, kind: "text" as const, name: id, mimeType: "text/plain", size: 1, text: "x" });
  const file = { id: "notes", kind: "text" as const, name: "notes.txt", mimeType: "text/plain", size: 1, text: "x" };
  expect(releasedPicks([pick("design-a"), pick("design-b"), file], [pick("design-b")])).toEqual(["design-a"]);
  expect(releasedPicks([pick("design-a"), file], [])).toEqual(["design-a"]);
  expect(releasedPicks([file], [])).toEqual([]);
  expect(releasedPicks([pick("design-a")], [pick("design-a")])).toEqual([]);
});

test("a pick's chip reads its number and comment over the element", async () => {
  const { browserPickRows, isBrowserPick, parseBrowserPick } =
    await import("../src/agent-session/acpmux/composer/browserPickModel");
  const t = ((key: string, values?: Record<string, unknown>) =>
    key === "composer.browserPick.kind" ? "Page element" : `“${String(values?.text ?? "")}”`) as never;
  expect(isBrowserPick({ id: "design-abc", text: card.text })).toBe(true);
  expect(isBrowserPick({ id: "other", text: card.text })).toBe(true);
  expect(isBrowserPick({ id: "other", text: "hello" })).toBe(false);
  expect(parseBrowserPick(card.text)).toMatchObject({ number: 1, comment: "Make this blue", tag: "button" });
  expect(browserPickRows(t, card.name, card.text)).toEqual({
    number: 1,
    title: [{ part: "comment", text: "Make this blue" }],
    caption: [
      { part: "kind", text: "Page element" },
      { part: "element", text: "button" },
      { part: "host", text: "example.com" },
    ],
  });
  const bare = card.text.replace("Comment: Make this blue\n", "");
  expect(browserPickRows(t, "1 · button · example.com", bare).title).toEqual([
    { part: "name", text: "button" },
    { part: "snippet", text: "“Buy now”" },
  ]);
});
