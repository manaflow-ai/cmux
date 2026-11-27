import { expect, test } from "bun:test";

// Blink keeps every text a canvas context measured for as long as the context lives, when the
// canvas never draws a frame: the text layout library's one measuring canvas grew with the chat
// (14,196 PlainTextNodes, 16.8 MB of the god chat's heap). measureContext.ts gives the library a
// context that measures on a real one and swaps that one for a new canvas when the library's
// caches start over.
test("the text layout library measures on a canvas the chat replaces when its caches start over", async () => {
  type Fake = { id: number; font: string; measured: string[] };
  const made: Fake[] = [];
  const scope = globalThis as { OffscreenCanvas?: unknown };
  const before = scope.OffscreenCanvas;
  scope.OffscreenCanvas = class {
    getContext() {
      const context: Fake & { measureText(text: string): { width: number } } = {
        id: made.length,
        font: "10px sans-serif",
        measured: [],
        measureText(text: string) {
          context.measured.push(text);
          return { width: text.length * 7 };
        },
      };
      made.push(context);
      return context;
    }
  };
  try {
    const { ensureMeasureContext, freshMeasureContext } = await import("../src/agent-session/acpmux/measureContext");
    const { prepare, clearCache } = await import("@chenglou/pretext");
    // Importing it measures nothing: the swap waits for the chat's first text.
    expect(made.length).toBe(0);
    ensureMeasureContext();
    // The library's canvas is the chat's: its first measure went to the chat's real context.
    expect(made.length).toBe(1);
    expect(made[0]!.measured.length).toBeGreaterThan(0);
    prepare("alpha beta", "13px Inter");
    expect(made[0]!.measured).toContain("alpha");
    expect(made[0]!.font).toBe("13px Inter");

    clearCache();
    expect(freshMeasureContext()).toBe(true);
    expect(made.length).toBe(2);
    // The font carries over, and the next measures go to the new canvas only.
    expect(made[1]!.font).toBe("13px Inter");
    const old = made[0]!.measured.length;
    prepare("gamma delta", "13px Inter");
    expect(made[1]!.measured).toContain("gamma");
    expect(made[0]!.measured.length).toBe(old);

    // A chat that never prepares enough text to clear the library's caches still gets a new canvas
    // every MEASURES_PER_CANVAS measures, so no canvas holds more measured words than that.
    const { MEASURES_PER_CANVAS } = await import("../src/agent-session/acpmux/measureContext");
    const words = Array.from({ length: MEASURES_PER_CANVAS * 2 + 10 }, (_, index) => `w${index}`);
    prepare(words.join(" "), "13px Inter");
    expect(made.length).toBeGreaterThanOrEqual(4);
    for (const each of made) expect(each.measured.length).toBeLessThanOrEqual(MEASURES_PER_CANVAS);
    expect(made.at(-1)!.font).toBe("13px Inter");
  } finally {
    scope.OffscreenCanvas = before;
  }
});
