// Interface Scale (app.uiScale) is WKWebView.pageZoom, so a column capped in CSS px grows on screen
// with it until it fills the pane and its margins collapse (#22257). The cap divides by the scale:
// the column keeps its on-screen width and only the type inside it grows.
import { expect, test } from "bun:test";
import { chatColumnOf } from "../src/agent-session/acpmux/chatWidth";
import { transcriptColumn } from "../src/agent-session/acpmux/model";

const onScreen = (panePoints: number, scale: number) => {
  const { inset, width } = transcriptColumn(panePoints / scale, chatColumnOf("standard", scale));
  return { inset: inset * scale, width: width * scale };
};

test("the chat column keeps its on-screen width at a larger interface scale", () => {
  expect(onScreen(843, 1)).toEqual({ inset: 61.5, width: 720 });
  for (const scale of [1.25, 1.5]) {
    const column = onScreen(843, scale);
    expect(column.width).toBeCloseTo(720, 6);
    expect(column.inset).toBeCloseTo(61.5, 6);
  }
});

test("a wide pane still caps the column at 800pt on screen at any interface scale", () => {
  for (const scale of [1, 1.5]) expect(onScreen(1600, scale).width).toBeCloseTo(800, 6);
});

test("the prose measure follows the scale", () => {
  expect(chatColumnOf("wideBlocks", 1.25).prose).toBeCloseTo(640, 6);
  expect(chatColumnOf("standard", 1.25).prose).toBe(Infinity);
});
