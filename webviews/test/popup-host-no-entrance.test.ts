// A New Tab menu with no room in a short pane shows past the window's edge in the native popup host,
// and opens there in one frame too (Leo 2026-10-22: no entry animations on the New Tab): while the
// root carries `data-new-tab` the request says `instant: true` (WebPopupHost.swift skips the
// entrance); anywhere else it leaves the flag out.
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
async function sent(): Promise<[string, unknown][]> {
  const calls: [string, unknown][] = [];
  const host = createPopupHost(
    async (call, params) => calls.push([call, params.instant]),
    () => () => {},
  );
  const owner = {};
  await host.show(MODEL, owner);
  host.update({ ...MODEL, highlighted: "0" }, owner);
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

test("anywhere else the request leaves the flag out", async () => {
  expect(await sent()).toEqual([
    ["show", undefined],
    ["update", undefined],
  ]);
});
