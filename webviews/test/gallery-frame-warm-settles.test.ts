// A gallery warm-up returns only once Vite's dependency optimizer has settled. The optimizer bundles
// the dependencies a load discovered after the load ends, and when the bundle changes it reloads
// every open page. A warm-up that returned at its first ready left that reload to land on the
// test's own page after the test had set it up: new-tab-list-motion lost its rows (#23257's run
// 39612287631, 2026-10-21; a fleet probe saw the reload 0.2 s after the warm-up returned).
// The browser and the server here are stand-ins: no engine, no Vite.
import { expect, test } from "bun:test";
import type { ViteDevServer } from "vite";
import { warmGalleryFrame } from "./support/galleryFrame";

type Browser = NonNullable<NonNullable<Parameters<typeof warmGalleryFrame>[2]>["browser"]>;

type Payload = { type: string };

/** A dev server whose optimizer bundles one discovered dependency, then reloads every page. */
function optimizingServer() {
  let finish = () => {};
  const processing = new Promise<void>((resolve) => (finish = resolve));
  const dep: { processing?: Promise<void> } = { processing };
  const client = {
    hot: { send: (_payload: Payload) => {} },
    waitForRequestsIdle: async () => {},
    depsOptimizer: { metadata: { discovered: { dep } } },
  };
  const server = {
    httpServer: { address: () => ({ port: 1 }) },
    environments: { client },
  } as unknown as ViteDevServer;
  /** As Vite's rerun does: the bundle commits, then the reload goes out a few microtasks later. */
  const settle = async () => {
    dep.processing = undefined;
    finish();
    await Promise.resolve();
    await Promise.resolve();
    client.hot.send({ type: "full-reload" });
  };
  return { server, settle };
}

/** A browser whose pages report ready as soon as they navigate; `reported` once one has. */
function readyBrowser() {
  const loads: number[] = [];
  let report = () => {};
  const reported = new Promise<void>((resolve) => (report = resolve));
  const browser = {
    newPage: async () => ({
      on: () => {},
      goto: async () => void loads.push(loads.length + 1),
      waitForFunction: async () => {},
      evaluate: async () => {
        report();
        return ["1", ""];
      },
      close: async () => {},
    }),
  } as unknown as Browser;
  return { browser, loads, reported };
}

test("a warm-up waits for the optimizer's bundle and loads again after the reload it sends", async () => {
  const { server, settle } = optimizingServer();
  const { browser, loads, reported } = readyBrowser();
  let returned = false;
  const warm = warmGalleryFrame(server, "agent-pane.new-tab", { browser }).then(() => (returned = true));
  // The page has reported ready; a warm-up that stops there has returned by the next macrotask.
  await reported;
  await new Promise((resolve) => setImmediate(resolve));
  expect(returned).toBe(false);
  await settle();
  await warm;
  expect(loads).toEqual([1, 2]);
});

test("a warm-up whose load finds nothing new returns after one load", async () => {
  const { browser, loads } = readyBrowser();
  const client = {
    hot: { send: (_payload: Payload) => {} },
    waitForRequestsIdle: async () => {},
    depsOptimizer: { metadata: { discovered: {} } },
  };
  const server = {
    httpServer: { address: () => ({ port: 1 }) },
    environments: { client },
  } as unknown as ViteDevServer;
  await warmGalleryFrame(server, "agent-pane.new-tab", { browser });
  expect(loads).toEqual([1]);
});
