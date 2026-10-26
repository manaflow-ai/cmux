import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { cutBetween, wholeLineCut } from "./lineCut";
const span = (top: number, bottom: number) => ({ top, bottom });
test.each([
  [[], 160, 160],
  [[span(150.25, 170)], 160, 150.25],
  [[span(140, 160), span(155, 180)], 160, 140],
  [[span(0, 400)], 160, 0],
  [[span(0, 159.9), span(160.1, 180)], 160, 160],
] as const)("cut avoids crossing rendered boxes: %j", (spans, limit, expected) => {
  expect(cutBetween(spans, limit)).toBe(expected);
  expect(cutBetween([...spans].reverse(), limit)).toBe(expected);
});

// Geometry supplied by the renderer: a card starts at 120, its body crosses the 160px cut.
test.each(["plain", "open", "closed", "host-only"])("keeps %s code cards atomic", (kind) => {
  const dom = new JSDOM('<div class="cv-codeblock"><header></header><diffs-container></diffs-container></div>');
  try {
    const rect = (top: number, bottom: number) => new dom.window.DOMRect(0, top, 640, bottom - top);
    const box = dom.window.document.body;
    box.style.width = "640px";
    const host = box.querySelector("diffs-container")!;
    if (kind === "plain") host.replaceWith(box.ownerDocument.createElement("code"));
    else host.attachShadow({ mode: kind === "closed" ? "closed" : "open" }).innerHTML = "<code>x</code>";
    if (kind === "host-only") box.replaceChildren(host);
    box.getBoundingClientRect = () => rect(0, 400);
    for (const element of box.querySelectorAll("*")) {
      const top = element.matches(".cv-codeblock") ? 120 : 150;
      element.getClientRects = () => [rect(top, 300)] as unknown as DOMRectList;
    }
    expect(wholeLineCut(box, 160)).toBe(kind === "host-only" ? 150 : 120);
  } finally {
    dom.window.close();
  }
});
