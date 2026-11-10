// "New since you looked" follows the viewer's pick (sinceView.ts): expanded shows the turn count and
// the recap, a click on the line collapses it to the line and its New tag, and hidden draws nothing
// and takes no room in the row estimate (model.ts).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { estimateRowHeight, SINCE_DIVIDER, type AcpmuxRow } from "../model";
import { SinceDivider } from "./SinceDivider";
import { setSinceView, sinceView } from "./sinceView";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "localStorage", "IntersectionObserver", "IS_REACT_ACT_ENVIRONMENT"];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const SINCE = {
  key: "s:41",
  seq: 41,
  turns: 3,
  recap: { key: "r", text: "The parser tolerates missing fields now.", awayMs: 60_000 },
};

async function mount() {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    localStorage: dom.window.localStorage,
    IntersectionObserver: class {
      observe() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  await act(async () => {
    root = createRoot(dom!.window.document.getElementById("root")!);
    root.render(<SinceDivider since={SINCE} />);
  });
  return dom.window.document;
}

test("a click on the line switches expanded and collapsed, and Hide draws nothing", async () => {
  const doc = await mount();
  await act(async () => setSinceView("expanded"));
  expect(doc.querySelector(".cv-since")?.getAttribute("data-view")).toBe("expanded");
  expect(doc.querySelector(".cv-since__count")).not.toBeNull();
  expect(doc.querySelector(".cv-since__tag")).not.toBeNull();
  expect(doc.querySelector(".cv-recap, [class*='recap']")).not.toBeNull();

  await act(async () => (doc.querySelector(".cv-since__line") as HTMLButtonElement).click());
  expect(sinceView()).toBe("collapsed");
  expect(doc.querySelector(".cv-since")?.getAttribute("data-view")).toBe("collapsed");
  expect(doc.querySelector(".cv-since__count")).toBeNull();
  expect(doc.querySelector(".cv-since__tag")).not.toBeNull();
  expect(doc.querySelector("[class*='recap']")).toBeNull();

  await act(async () => setSinceView("hidden"));
  expect(doc.querySelector(".cv-since")).toBeNull();
  // Kept across launches.
  expect(dom!.window.localStorage.getItem("cmux.agentPane.since.view")).toBe("hidden");
  await act(async () => setSinceView("expanded"));
  expect(doc.querySelector(".cv-since")).not.toBeNull();
});

test("the row estimate follows the pick: no room while hidden, no recap while collapsed", async () => {
  await mount();
  const row: AcpmuxRow = { id: SINCE_DIVIDER, version: 1, at: 0, kind: SINCE_DIVIDER, since: SINCE };
  setSinceView("expanded");
  const expanded = estimateRowHeight(row, 640);
  setSinceView("collapsed");
  expect(estimateRowHeight(row, 640)).toBe(28);
  expect(expanded).toBeGreaterThan(28);
  setSinceView("hidden");
  expect(estimateRowHeight(row, 640)).toBe(0);
  setSinceView("expanded");
});
