// scripts/gallery/capture-states.mjs waits on a stage frame's data-gallery-ready. A frame that cannot
// draw its entry sets it to "error" (an entry with no covers did, RFD 0134's settings gallery): the
// capture fails at once with the frame's text instead of a bare TimeoutError after 90 s.
import { describe, expect, test } from "bun:test";
import { waitForFrame } from "../scripts/gallery/frameReady.mjs";

type Fn = () => unknown;
// A stand-in page: evaluate and waitForFunction run their callbacks against a fake document.
function fakePage(ready: string | undefined, text: string) {
  const doc = { documentElement: { dataset: { galleryReady: ready } }, body: { innerText: text } };
  const run = (fn: Fn) => {
    const saved = (globalThis as { document?: unknown }).document;
    (globalThis as { document?: unknown }).document = doc;
    try {
      return fn();
    } finally {
      (globalThis as { document?: unknown }).document = saved;
    }
  };
  return {
    evaluate: async (fn: Fn) => run(fn),
    waitForFunction: async (fn: Fn, _arg: unknown, options: { timeout: number }) => {
      if (!run(fn)) throw new Error(`TimeoutError: waitForFunction: Timeout ${options.timeout}ms exceeded.`);
    },
  };
}

describe("waitForFrame", () => {
  test("a drawn frame passes", async () => {
    await waitForFrame(fakePage("1", "Settings"), "pages.settings-app-update");
  });

  test("a frame error fails with the frame's own text", async () => {
    const page = fakePage("error", 'No gallery entry "pages.x".\n\nsrc/x.gallery.ts: no covers');
    await expect(waitForFrame(page, "pages.x")).rejects.toThrow(
      'the frame did not draw pages.x: No gallery entry "pages.x". src/x.gallery.ts: no covers',
    );
  });

  test("a frame still loading times out", async () => {
    await expect(waitForFrame(fakePage(undefined, ""), "pages.x", 5)).rejects.toThrow("Timeout 5ms");
  });
});
