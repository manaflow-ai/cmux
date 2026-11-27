// The hot-swap probe's cold load (scripts/hot-reload-proof.mjs) loads the pane again when Vite's
// optimizer bundled mid-load and the entry's import failed (the 2026-11-27 08:11Z probe run waited out
// its 240 s on a page that never mounted). These check which errors count and that the wait ends.
import { expect, test } from "bun:test";
// @ts-expect-error: a plain .mjs script module
import { isDynamicImportFailure, optimizerSettled } from "../scripts/hot-reload-proof-load.mjs";

test("only a module the browser could not fetch counts as the optimizer's race", () => {
  expect(
    isDynamicImportFailure(
      "Failed to fetch dynamically imported module: http://127.0.0.1:43221/src/agent-session/acpmux/main.tsx",
    ),
  ).toBe(true);
  expect(isDynamicImportFailure("error loading dynamically imported module: x.js")).toBe(true);
  expect(isDynamicImportFailure("TypeError: Cannot read properties of undefined")).toBe(false);
  expect(isDynamicImportFailure(undefined)).toBe(false);
});

test("waits for the dependencies the optimizer is still bundling", async () => {
  let release!: () => void;
  const dep: { processing?: Promise<void> } = {};
  dep.processing = new Promise<void>((resolve) => (release = resolve)).then(() => {
    dep.processing = undefined;
  });
  const server = {
    environments: {
      client: { waitForRequestsIdle: async () => {}, depsOptimizer: { metadata: { discovered: { react: dep } } } },
    },
  };
  let settled = false;
  const waiting = optimizerSettled(server, () => 10_000).then(() => (settled = true));
  await new Promise((resolve) => setTimeout(resolve, 20));
  expect(settled).toBe(false);
  release();
  await waiting;
  expect(settled).toBe(true);
});

test("a stuck optimizer ends the wait at the bound", async () => {
  const server = { environments: { client: { waitForRequestsIdle: () => new Promise<void>(() => {}) } } };
  const started = performance.now();
  await optimizerSettled(server, () => 30);
  expect(performance.now() - started).toBeLessThan(5_000);
});
