// Leo, 2026-10-15: a loopback address a turn merely mentioned (a tool output line naming
// http://127.0.0.1:5174/) drew the whole preview card: a 58px head and, under it, a 180px empty
// box holding one centered "Load preview" button. Weird, badly styled, too big. Before the reader
// loads it, the card is one compact row: the address, then "Load preview" beside Open in tab and
// Open in. The thumbnail's box appears only once the reader clicks, which stays the only way the
// pane requests a loopback page (previewUrl.ts).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { PreviewCard } from "../src/agent-session/acpmux/conversation/PreviewCard";

const card = (url: string) => {
  const html = renderToStaticMarkup(<PreviewCard url={url} onOpen={() => undefined} />);
  return new JSDOM(html).window.document;
};

test("an unloaded card is one row, with Load preview among its actions and no empty box", () => {
  const doc = card("http://127.0.0.1:5174/");
  const root = doc.querySelector(".acpmux-turn-preview")!;
  expect(root).not.toBeNull();
  // The head is the card's only part: no placeholder box, no frame, nothing loaded.
  expect([...root.children].map((child) => child.className)).toEqual(["acpmux-turn-preview-head"]);
  expect(doc.querySelector(".acpmux-turn-preview-unloaded")).toBeNull();
  expect(doc.querySelector(".acpmux-turn-preview-frame")).toBeNull();
  expect(doc.querySelector("iframe")).toBeNull();
  const load = doc.querySelector(".acpmux-turn-preview-head .acpmux-turn-preview-load");
  expect(load?.textContent).toBe("Load preview");
  expect(root.hasAttribute("data-compact")).toBe(true);
});
