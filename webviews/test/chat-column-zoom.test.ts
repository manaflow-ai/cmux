import { describe, expect, test } from "bun:test";
import { DEFAULT_CHAT_DISPLAY } from "../src/agent-session/acpmux/chatDisplay";
import { displayColumn } from "../src/agent-session/acpmux/chatWidth";
import { transcriptColumn } from "../src/agent-session/acpmux/model";

describe("chat column during repeated zoom", () => {
  const steps = Array.from({ length: 16 }, (_, index) => (index + 5) / 10);
  const zooms = [...steps, ...steps.toReversed()];

  for (const pane of [1288, 1441, 1920]) {
    for (const width of [640, 800, 960]) {
      test(`${width}px column keeps both screen edges in a ${pane}px pane`, () => {
        for (const zoom of zooms) {
          const column = transcriptColumn(pane / zoom, displayColumn({ ...DEFAULT_CHAT_DISPLAY, width }, zoom));
          expect(column.width * zoom).toBeCloseTo(width, 6);
          expect(column.inset * zoom).toBeCloseTo((pane - width) / 2, 6);
          expect(column.insetEnd * zoom).toBeCloseTo((pane - width) / 2, 6);
        }
      });
    }
  }

  test("a narrow pane keeps the page edge while zooming", () => {
    for (const zoom of zooms) {
      const column = transcriptColumn(420 / zoom, displayColumn(DEFAULT_CHAT_DISPLAY, zoom));
      expect(column.inset).toBe(16);
      expect(column.insetEnd).toBe(16);
      expect(column.width * zoom).toBeCloseTo(420 - 32 * zoom, 6);
    }
  });
});
