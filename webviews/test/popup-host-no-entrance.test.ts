// A New Tab menu with no room in a short pane shows past the window's edge in the native popup host
// (popupHost.ts, WebPopupHost.swift). It opens there in one frame too (Leo 2026-10-22: "we should
// basically have no entry animations a lot of the time, esp here all over the new tab area... exit
// animations are ok tho."): while a New Tab page shows (`data-new-tab` on the root,
// newtab/noEntryMotion.ts), the request says `instant: true`, and the host skips the card's
// entrance (Motion+Popup.swift `showPopupAtOnce`). Anywhere else the request leaves it out.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createPopupHost, type PopupModel } from "../src/ui/popupHost";

const scope = globalThis as Record<string, unknown>;
const had = "document" in scope;
const saved = scope.document;
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body></body></html>");
  scope.document = dom.window.document;
});
afterAll(() => {
  if (had) scope.document = saved;
  else delete scope.document;
});

const MODEL: PopupModel = {
  items: [{ id: "0", label: "cmux" }],
  highlighted: null,
  anchor: { left: 10, top: 10, right: 120, bottom: 30 },
  side: "bottom",
  align: "start",
  width: 200,
  kind: "menu",
};

/// A host over a fake native side, and what each call sent there.
function recordingHost() {
  const sent: [string, Record<string, unknown>][] = [];
  const host = createPopupHost(
    async (call, params) => {
      sent.push([call, params]);
      return { shown: true };
    },
    () => () => {},
  );
  return { host, sent, owner: {} };
}

test("on a New Tab, the menu it shows past the window's edge asks for no entrance", async () => {
  dom.window.document.documentElement.setAttribute("data-new-tab", "");
  try {
    const { host, sent, owner } = recordingHost();
    await host.show(MODEL, owner);
    host.update({ ...MODEL, highlighted: "0" }, owner);
    expect(sent.map(([call, params]) => [call, params.instant])).toEqual([
      ["show", true],
      ["update", true],
    ]);
  } finally {
    dom.window.document.documentElement.removeAttribute("data-new-tab");
  }
});

test("anywhere else the request leaves the flag out, so the menu opens with its motion", async () => {
  const { host, sent, owner } = recordingHost();
  await host.show(MODEL, owner);
  host.update({ ...MODEL, highlighted: "0" }, owner);
  expect(sent.map(([call, params]) => [call, "instant" in params])).toEqual([
    ["show", false],
    ["update", false],
  ]);
});
