// A New Tab permission pick made before the page's actions connect belongs to the page
// (heldModePick.ts): it survives the chips unmounting (a first send leaves the New Tab page) and
// runs when the connect flushes it (#37858).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { flushHeldModePick, heldModePickForTest, holdModePick } from "./heldModePick";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = new Map<string, unknown>();

afterEach(async () => {
  flushHeldModePick();
  if (root) act(() => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const key of keys) {
    const value = saved.get(key);
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

test("a pick held before the connect runs on flush after its chip unmounted", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const key of keys) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  const ran: string[] = [];
  let settled: Promise<unknown> | undefined;
  function Chip() {
    // The chip takes the pick on its first draw, as the permission menu's pick would.
    settled ??= holdModePick("bypassPermissions", async (modeId) => {
      ran.push(modeId);
      return "applied";
    });
    return null;
  }
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(<Chip />));
  expect(heldModePickForTest()).toBe("bypassPermissions");
  // The first send leaves the New Tab page: the chips go before the connect.
  act(() => root!.unmount());
  root = undefined;
  expect(ran).toEqual([]);
  // The connect installs the page's actions and flushes, with no chip mounted.
  flushHeldModePick();
  expect(await settled).toBe("applied");
  expect(ran).toEqual(["bypassPermissions"]);
  expect(heldModePickForTest()).toBeUndefined();
});

test("a newer pick replaces a held one; only the newer runs", async () => {
  const ran: string[] = [];
  const run = async (modeId: string) => void ran.push(modeId);
  const first = holdModePick("default", run);
  const second = holdModePick("bypassPermissions", run);
  await first;
  flushHeldModePick();
  await second;
  expect(ran).toEqual(["bypassPermissions"]);
});

test("a refused run rejects the pick's promise, so the chip goes back", async () => {
  const pick = holdModePick("bypassPermissions", async () => {
    throw new Error("refused");
  });
  flushHeldModePick();
  await expect(pick).rejects.toThrow("refused");
});

test("a flush with nothing held does nothing", () => {
  expect(() => flushHeldModePick()).not.toThrow();
});
