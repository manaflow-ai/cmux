// warmGalleryFrame's retries on a cold dev server, driven by a stand-in browser (no engine needed).
//
// #26637's warm-up on a cold fleet worker (2026-10-28): the dependency optimizer bundled again
// while the stage loaded, the stage failed to mount on "Failed to fetch dynamically imported
// module", and the next goto on that page never committed, so one goto spent the whole 100 s
// budget. A fresh page, once the optimizer settled, loaded in about 1 s.
import { expect, test } from "bun:test";
import { optimizerRace, stalled, warmGalleryFrame } from "./support/galleryFrame";

type Step = { goto?: Error; ready?: string; text?: string };

/** A browser whose Nth page plays steps[N] (then `rest`): a goto that fails, or the stage's ready flag and text. */
function fakeBrowser(steps: Step[], rest: Step = { ready: "1" }) {
  const pages: { closed: boolean; gotos: string[] }[] = [];
  const browser = {
    async newPage() {
      const step = steps[pages.length] ?? rest;
      const record = { closed: false, gotos: [] as string[] };
      pages.push(record);
      return {
        on() {},
        async goto(url: string) {
          record.gotos.push(url);
          if (step.goto) throw step.goto;
        },
        async waitForFunction() {},
        async evaluate() {
          return [step.ready ?? "1", step.text ?? ""];
        },
        async close() {
          record.closed = true;
        },
      };
    },
  };
  return { browser: browser as never, pages };
}

function timeout(ms: number): Error {
  const error = new Error(
    `page.goto: Timeout ${ms}ms exceeded.\nCall log:\n  - navigating to "http://127.0.0.1:1/gallery/frame.html"`,
  );
  error.name = "TimeoutError";
  return error;
}

const STALE_IMPORT =
  "agent-pane.chat-width#default failed to mount:\nTypeError: Failed to fetch dynamically imported module: http://127.0.0.1:35565/gallery/src/agent-session/acpmux/main.tsx";

test("a stale optimized import and a goto that never commits each load again on a fresh page", async () => {
  const { browser, pages } = fakeBrowser([
    { ready: "error", text: STALE_IMPORT },
    { goto: timeout(30_000) },
    { ready: "1" },
  ]);
  await warmGalleryFrame("http://127.0.0.1:1", "agent-pane.chat-width", { browser });
  expect(pages.length).toBe(3);
  expect(pages.every((page) => page.closed)).toBe(true);
  expect(pages.every((page) => page.gotos.length === 1)).toBe(true);
});

test("a stage that fails to mount for its own reason fails the warm-up at once", async () => {
  const { browser, pages } = fakeBrowser([
    { ready: "error", text: "agent-pane.chat-width failed to mount:\nTypeError: x is undefined" },
  ]);
  await expect(warmGalleryFrame("http://127.0.0.1:1", "agent-pane.chat-width", { browser })).rejects.toThrow(
    "TypeError: x is undefined",
  );
  expect(pages.length).toBe(1);
  expect(pages[0]!.closed).toBe(true);
});

test("a refused connection is no reload and fails the warm-up at once", async () => {
  const { browser, pages } = fakeBrowser([
    { goto: new Error("page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:1/") },
  ]);
  await expect(warmGalleryFrame("http://127.0.0.1:1", "agent-pane.chat-width", { browser })).rejects.toThrow(
    "ERR_CONNECTION_REFUSED",
  );
  expect(pages.length).toBe(1);
});

test("a stale import that never clears fails at the deadline with its message", async () => {
  const { browser } = fakeBrowser([], { ready: "error", text: STALE_IMPORT });
  await expect(
    warmGalleryFrame("http://127.0.0.1:1", "agent-pane.chat-width", { browser, timeoutMs: 50 }),
  ).rejects.toThrow(/Failed to fetch dynamically imported module.*\n?.*at the 50 ms deadline/s);
});

test("optimizerRace and stalled name only the optimizer's own failures", () => {
  expect(optimizerRace(STALE_IMPORT)).toBe(true);
  expect(optimizerRace("TypeError: error loading dynamically imported module: http://x/a.js")).toBe(true);
  expect(optimizerRace("TypeError: x is undefined")).toBe(false);
  expect(optimizerRace(null)).toBe(false);
  expect(stalled(timeout(84_902))).toBe(true);
  expect(stalled(new Error("TimeoutError: goto: Timeout 84902ms exceeded."))).toBe(false); // name is Error
  expect(
    stalled(Object.assign(new Error("waitForFunction: Timeout 30000ms exceeded."), { name: "TimeoutError" })),
  ).toBe(false);
});
