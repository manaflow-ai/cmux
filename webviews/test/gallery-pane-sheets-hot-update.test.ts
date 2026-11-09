// A stylesheet save in the agent pane, or in any page the app serves live, must not wait on the
// gallery's sheet list. The list (dev-server/galleryHost.ts agentPaneStylesheets) comes from running
// bundle.mjs over dev.tsx, about 600 ms, and only the gallery's combined pane sheet needs it. The
// first stylesheet save after a page load ran it synchronously inside Vite's update: 676 ms from the
// save to the change on screen, against 49 ms for the next save of the same sheet
// (scripts/hot-reload-proof.mjs, goal hot-swap-fast).
import { expect, test } from "bun:test";
import path from "node:path";
import { galleryModules } from "../dev-server/galleryHost";

const WEBVIEWS = path.resolve(import.meta.dir, "..");
const SHEET = path.join(WEBVIEWS, "src/agent-session/acpmux/bottomStack.css");
const COMPONENT = path.join(WEBVIEWS, "src/agent-session/acpmux/ComposerFoot.tsx");
const COMBINED = path.join(WEBVIEWS, "src/gallery/agent-pane.virtual.css");

type Update = { file: string; modules: unknown[]; server: unknown };
const hotUpdate = (update: Update) => {
  const hook = galleryModules().handleHotUpdate as unknown as (update: Update) => unknown;
  return hook.call({}, update);
};

function fakeServer(combined: unknown) {
  const invalidated: unknown[] = [];
  return {
    invalidated,
    moduleGraph: {
      getModuleById: (id: string) => (id === COMBINED ? combined : undefined),
      invalidateModule: (module: unknown) => invalidated.push(module),
    },
    ws: { send: () => {} },
  };
}

test("with no combined pane sheet loaded, a stylesheet or component save returns at once", () => {
  for (const file of [SHEET, COMPONENT]) {
    const server = fakeServer(undefined);
    const started = performance.now();
    expect(hotUpdate({ file, modules: [], server })).toBeUndefined();
    // Deriving the list spawns a bundle of dev.tsx: far more than this.
    expect(performance.now() - started).toBeLessThan(200);
    expect(server.invalidated).toEqual([]);
  }
});

test("with the gallery's combined pane sheet loaded, a pane stylesheet save updates it in place", () => {
  const combined = { id: COMBINED };
  const server = fakeServer(combined);
  expect(hotUpdate({ file: SHEET, modules: ["sheet"], server })).toEqual(["sheet", combined]);
  expect(server.invalidated).toEqual([combined]);
});
