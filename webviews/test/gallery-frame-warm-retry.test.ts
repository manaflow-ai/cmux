// warmGalleryFrame's retries on a cold dev server, driven by a stand-in browser and dev server (no
// engine needed).
//
// #26637's warm-up on a cold fleet worker (2026-10-28): the dependency optimizer bundled again
// while the stage loaded and reloaded the page, the stage failed to mount on "Failed to fetch
// dynamically imported module", and the next goto on that page never committed, so one goto spent
// the whole 100 s budget. A fresh page, once the optimizer settled, loaded in about 1 s. A failed
// import with no optimizer reload (a missing module) must still fail at once.
import { expect, test } from "bun:test";
import type { ViteDevServer } from "vite";
import { dynamicImportFailed, outdatedOptimizeDep, stalled, warmGalleryFrame } from "./support/galleryFrame";

/** One page's load: a goto that fails, or the stage's ready flag and text; `reload` sends a full reload. */
type Step = { goto?: Error; ready?: string; text?: string; reload?: boolean };

/** A dev server with only what warmGalleryFrame reads: its port, hot channel and optimizer. */
function fakeServer() {
  const client = {
    hot: { send(_payload: unknown) {} },
    async waitForRequestsIdle() {},
    depsOptimizer: { metadata: { discovered: {} } },
  };
  const server = { httpServer: { address: () => ({ port: 1 }) }, environments: { client } };
  // The optimizer's reload goes through the hot channel, which warmGalleryFrame counts.
  const reload = () => server.environments.client.hot.send({ type: "full-reload" });
  return { server: server as unknown as ViteDevServer, reload };
}

/** A browser whose Nth page plays steps[N] (then `rest`). */
function fakeBrowser(steps: Step[], rest: Step = { ready: "1" }, reload: () => void = () => {}) {
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
          if (step.reload) reload();
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
const MISSING_MODULE =
  "agent-pane.chat-width#default failed to mount:\nTypeError: Failed to fetch dynamically imported module: http://127.0.0.1:35565/gallery/src/agent-session/acpmux/Gone.tsx";
const OUTDATED =
  'agent-pane.chat-width#default failed to mount:\nError: 504 (Outdated Optimize Dep) for "/gallery/node_modules/.vite/deps/react.js"';

test("an import that failed while the optimizer reloaded, then a stuck goto, each load again on a fresh page", async () => {
  const { server, reload } = fakeServer();
  const { browser, pages } = fakeBrowser(
    [{ ready: "error", text: STALE_IMPORT, reload: true }, { goto: timeout(30_000) }, { ready: "1" }],
    { ready: "1" },
    reload,
  );
  await warmGalleryFrame(server, "agent-pane.chat-width", { browser });
  expect(pages.length).toBe(3);
  expect(pages.every((page) => page.closed)).toBe(true);
  expect(pages.every((page) => page.gotos.length === 1)).toBe(true);
});

test("a missing module fails on the first load, with no optimizer reload, whatever the server", async () => {
  const { server, reload } = fakeServer();
  for (const target of [server, "http://127.0.0.1:1"] as const) {
    const { browser, pages } = fakeBrowser([{ ready: "error", text: MISSING_MODULE }], { ready: "1" }, reload);
    await expect(warmGalleryFrame(target, "agent-pane.chat-width", { browser })).rejects.toThrow("Gone.tsx");
    expect(pages.length).toBe(1);
    expect(pages[0]!.closed).toBe(true);
  }
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

test("Vite's Outdated Optimize Dep loads again, and fails at the deadline with its message if it never clears", async () => {
  const once = fakeBrowser([{ ready: "error", text: OUTDATED }, { ready: "1" }]);
  await warmGalleryFrame("http://127.0.0.1:1", "agent-pane.chat-width", { browser: once.browser });
  expect(once.pages.length).toBe(2);
  const never = fakeBrowser([], { ready: "error", text: OUTDATED });
  await expect(
    warmGalleryFrame("http://127.0.0.1:1", "agent-pane.chat-width", { browser: never.browser, timeoutMs: 50 }),
  ).rejects.toThrow(/Outdated Optimize Dep.*at the 50 ms deadline/s);
});

test("the matchers name only the optimizer's own evidence and stuck gotos", () => {
  expect(outdatedOptimizeDep(OUTDATED)).toBe(true);
  expect(outdatedOptimizeDep(STALE_IMPORT)).toBe(false);
  expect(outdatedOptimizeDep(null)).toBe(false);
  expect(dynamicImportFailed(STALE_IMPORT)).toBe(true);
  expect(dynamicImportFailed("TypeError: x is undefined")).toBe(false);
  expect(stalled(timeout(84_902))).toBe(true);
  expect(stalled(new Error("TimeoutError: goto: Timeout 84902ms exceeded."))).toBe(false); // name is Error
  expect(
    stalled(Object.assign(new Error("waitForFunction: Timeout 30000ms exceeded."), { name: "TimeoutError" })),
  ).toBe(false);
});
