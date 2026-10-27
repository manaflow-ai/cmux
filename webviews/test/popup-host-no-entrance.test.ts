// Escaped menus and lists open instantly in the native host on every page (Leo 2026-10-24:
// "No fade in ever for any of these"), just like their in-page surfaces. New Tab also keeps
// tooltips instant; other tooltips retain their entrance. WebPopupHost.swift consumes `instant`
// by choosing showPopupAtOnce instead of openPopup, while close motion stays unchanged.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createPopupHost, type PopupModel } from "../src/ui/popupHost";

const scope = globalThis as Record<string, unknown>;
const saved = Object.getOwnPropertyDescriptor(scope, "document");
const dom = new JSDOM("<!doctype html>");
beforeAll(() => void (scope.document = dom.window.document));
afterAll(() => (saved ? Object.defineProperty(scope, "document", saved) : delete scope.document));

const MODEL: PopupModel = {
  items: [{ id: "0", label: "cmux" }],
  highlighted: null,
  anchor: { left: 10, top: 10, right: 120, bottom: 30 },
  side: "bottom",
  align: "start",
  width: 200,
};

/// Shows and updates a menu through a fake native side; what each call sent there.
async function sent(kind?: PopupModel["kind"]): Promise<[string, unknown][]> {
  const calls: [string, unknown][] = [];
  const host = createPopupHost(
    async (call, params) => calls.push([call, params.instant]),
    () => () => {},
  );
  const owner = {};
  await host.show({ ...MODEL, ...(kind ? { kind } : {}) }, owner);
  host.update({ ...MODEL, ...(kind ? { kind } : {}), highlighted: "0" }, owner);
  return calls;
}

test("on a New Tab, the menu it shows past the window's edge asks for no entrance", async () => {
  dom.window.document.documentElement.setAttribute("data-new-tab", "");
  try {
    expect(await sent()).toEqual([
      ["show", true],
      ["update", true],
    ]);
  } finally {
    dom.window.document.documentElement.removeAttribute("data-new-tab");
  }
});

test("menus and lists outside New Tab ask the native host for no entrance", async () => {
  for (const kind of [undefined, "menu", "list"] as const)
    expect({ kind, calls: await sent(kind) }).toEqual({
      kind,
      calls: [
        ["show", true],
        ["update", true],
      ],
    });
});

test("a tooltip outside New Tab keeps its existing entrance", async () => {
  expect(await sent("tooltip")).toEqual([
    ["show", undefined],
    ["update", undefined],
  ]);
});
