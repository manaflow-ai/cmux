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
import {
  dynamicImportFailed,
  NAVIGATION_ATTEMPT_MS,
  outdatedOptimizeDep,
  stalled,
  warmGalleryFrame,
} from "./support/galleryFrame";

/** One page's load: a goto that fails, or the stage's ready flag and text; `bundle` starts an optimizer run. */
type Step = { goto?: Error; ready?: string; text?: string; bundle?: boolean };

/**
 * A dev server with only what warmGalleryFrame reads: its port, hot channel and optimizer. `bundle()`
 * starts an optimizer run as a page's load would: the dependency it discovers is processing until
 * the next macrotask, and only then does the optimizer send its full reload (late, as Vite does),
 * so a warm-up that did not wait for the optimizer would miss the reload. `idle` replaces the
 * request-idle wait (a promise that never settles models a stuck optimizer).
 */
function fakeServer({ idle }: { idle?: () => Promise<void> } = {}) {
  const discovered: Record<string, { processing?: Promise<void> }> = {};
  const client = {
    hot: { send(_payload: unknown) {} },
    waitForRequestsIdle: idle ?? (async () => {}),
    depsOptimizer: { metadata: { discovered } },
  };
  const server = { httpServer: { address: () => ({ port: 1 }) }, environments: { client } };
  let runs = 0;
  const bundle = () => {
    const dep = { processing: undefined as Promise<void> | undefined };
    dep.processing = new Promise<void>((resolve) =>
      setTimeout(() => {
        dep.processing = undefined;
        // The hot channel warmGalleryFrame counts (it wraps send on its first look).
        server.environments.client.hot.send({ type: "full-reload" });
        resolve();
      }, 0),
    );
    discovered[`dep${runs++}`] = dep;
  };
  return { server: server as unknown as ViteDevServer, bundle };
}

/** A browser whose Nth page plays steps[N] (then `rest`); `bundle` starts an optimizer run. */
function fakeBrowser(steps: Step[], rest: Step = { ready: "1" }, bundle: () => void = () => {}) {
  const pages: { closed: boolean; gotos: { url: string; timeout: number | undefined }[] }[] = [];
  const browser = {
    async newPage() {
      const step = steps[pages.length] ?? rest;
      const record = { closed: false, gotos: [] as { url: string; timeout: number | undefined }[] };
      pages.push(record);
      return {
        on() {},
        async goto(url: string, options?: { timeout?: number }) {
          record.gotos.push({ url, timeout: options?.timeout });
          if (step.bundle) bundle();
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
const MISSING_MODULE =
  "agent-pane.chat-width#default failed to mount:\nTypeError: Failed to fetch dynamically imported module: http://127.0.0.1:35565/gallery/src/agent-session/acpmux/Gone.tsx";
const OUTDATED =
  'agent-pane.chat-width#default failed to mount:\nError: 504 (Outdated Optimize Dep) for "/gallery/node_modules/.vite/deps/react.js"';

test("an import that failed while the optimizer re-bundled loads again once its late reload is counted", async () => {
  const { server, bundle } = fakeServer();
  const { browser, pages } = fakeBrowser(
    [{ ready: "error", text: STALE_IMPORT, bundle: true }, { goto: timeout(30_000) }, { ready: "1" }],
    { ready: "1" },
    bundle,
  );
  await warmGalleryFrame(server, "agent-pane.chat-width", { browser });
  // The first page's reload arrives only after the optimizer settled; then a stuck goto; then a load.
  expect(pages.length).toBe(3);
  expect(pages.every((page) => page.closed)).toBe(true);
  expect(pages.every((page) => page.gotos.length === 1)).toBe(true);
});

test("a missing module fails on the first load: the optimizer settles and sends no reload", async () => {
  const { server, bundle } = fakeServer();
  for (const target of [server, "http://127.0.0.1:1"] as const) {
    const { browser, pages } = fakeBrowser([{ ready: "error", text: MISSING_MODULE }], { ready: "1" }, bundle);
    await expect(warmGalleryFrame(target, "agent-pane.chat-width", { browser })).rejects.toThrow("Gone.tsx");
    expect(pages.length).toBe(1);
    expect(pages[0]!.closed).toBe(true);
  }
});

test("each goto gets at most NAVIGATION_ATTEMPT_MS of the budget, and less when less is left", async () => {
  const roomy = fakeBrowser([{ ready: "1" }]);
  await warmGalleryFrame("http://127.0.0.1:1", "agent-pane.chat-width", { browser: roomy.browser });
  expect(roomy.pages[0]!.gotos[0]!.timeout).toBe(NAVIGATION_ATTEMPT_MS);
  const tight = fakeBrowser([{ ready: "1" }]);
  await warmGalleryFrame("http://127.0.0.1:1", "agent-pane.chat-width", { browser: tight.browser, timeoutMs: 5_000 });
  expect(tight.pages[0]!.gotos[0]!.timeout).toBeLessThanOrEqual(5_000);
});

test("an optimizer whose requests never go idle fails at the deadline and closes the page", async () => {
  const { server } = fakeServer({ idle: () => new Promise<void>(() => {}) });
  const { browser, pages } = fakeBrowser([{ ready: "1" }]);
  await expect(warmGalleryFrame(server, "agent-pane.chat-width", { browser, timeoutMs: 50 })).rejects.toThrow(
    "requests did not go idle",
  );
  expect(pages.length).toBe(1);
  expect(pages[0]!.closed).toBe(true);
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
