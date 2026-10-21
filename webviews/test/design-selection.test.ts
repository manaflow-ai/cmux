// Design mode (plans/cmux-next/design-mode-DESIGN.md): a highlight in a browser pane reaches the
// agent chat as the host's `designSelection` event, and the composer holds it as chips: the
// element's details as a text chip and its screenshot crop as an image chip, both going with the
// next message. Highlighting the same element again replaces its chips (same ids).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

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

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

const card = {
  id: "design-abc",
  name: "Design: button · example.com",
  text: "Page: https://example.com/\nSelector: #buy",
  image: { mimeType: "image/png", data: "iVBORw0KGgo=" },
};

test("a highlight becomes a text chip and an image chip with stable ids", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const chips = designSelectionChips(card);
  expect(chips.map((chip) => [chip.id, chip.kind, chip.name])).toEqual([
    ["design-abc", "text", "Design: button · example.com"],
    ["design-abc-shot", "image", "Design: button · example.com.png"],
  ]);
  expect(chips[0]?.text).toBe(card.text);
  expect(chips[1]?.data).toBe("iVBORw0KGgo=");
  expect(chips[1]?.mimeType).toBe("image/png");
});

test("a highlight without a crop is one text chip; a bad value is none", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  expect(designSelectionChips({ ...card, image: undefined }).map((chip) => chip.kind)).toEqual(["text"]);
  expect(designSelectionChips({ id: "x", name: "n" })).toEqual([]);
  expect(designSelectionChips(null)).toEqual([]);
  expect(designSelectionChips({ ...card, image: { mimeType: "text/html", data: "PGI+" } }).map((c) => c.kind)).toEqual([
    "text",
  ]);
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

test("a removed highlight names both of its chips; a card is no removal", async () => {
  const { designSelectionRemovals } = await import("../src/agent-session/acpmux/designSelection");
  expect(designSelectionRemovals({ removed: "design-abc" })).toEqual(["design-abc", "design-abc-shot"]);
  expect(designSelectionRemovals(card)).toEqual([]);
  expect(designSelectionRemovals({ removed: "" })).toEqual([]);
  expect(designSelectionRemovals(null)).toEqual([]);
});
