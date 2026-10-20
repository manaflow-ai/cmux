// l10n-allow-file: test fixtures, not shipped UI.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "https://pane.test/" });
const scope = globalThis as Record<string, unknown>;
const replacements = { document: dom.window.document, location: dom.window.location };
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
let instance = 0;

beforeEach(() => {
  for (const name of document.documentElement.getAttributeNames()) document.documentElement.removeAttribute(name);
  dom.reconfigure({ url: "https://pane.test/" });
});
afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

// Each page captures its host attributes once, before its first layout arrives.
const load = async (): Promise<typeof import("../src/agent-session/acpmux/labs")> =>
  import(`../src/agent-session/acpmux/labs.ts?page=${instance++}`);

test("app off survives an absent layout entry and a conflicting dev URL", async () => {
  document.documentElement.setAttribute("data-lab-chat-viewer", "off");
  dom.reconfigure({ url: "https://pane.test/?data-lab-chat-viewer=on" });
  const { configureLabs, labOn } = await load();
  expect(labOn("chatViewer")).toBe(false);
  for (const layout of [undefined, {}, { labs: {} }, { labs: { chatViewer: "on" } }]) {
    configureLabs(layout);
    expect(labOn("chatViewer")).toBe(false);
    expect(document.documentElement.getAttribute("data-lab-chat-viewer")).toBe("off");
  }
});

test("layout beats app off, and removing its entry restores the captured app value", async () => {
  document.documentElement.setAttribute("data-lab-chat-viewer", "off");
  const { configureLabs, labOn } = await load();
  configureLabs({ labs: { chatViewer: true } });
  expect(labOn("chatViewer")).toBe(true);
  expect(document.documentElement.getAttribute("data-lab-chat-viewer")).toBe("on");
  configureLabs({ labs: {} });
  expect(labOn("chatViewer")).toBe(false);
  expect(document.documentElement.getAttribute("data-lab-chat-viewer")).toBe("off");
  configureLabs({ labs: { chatViewer: true } });
  configureLabs(undefined);
  expect(labOn("chatViewer")).toBe(false);
});

test("layout false beats app on and removing the layout restores on", async () => {
  document.documentElement.setAttribute("data-lab-chat-viewer", "on");
  const { configureLabs, labOn } = await load();
  configureLabs({ labs: { chatViewer: false } });
  expect(labOn("chatViewer")).toBe(false);
  configureLabs({});
  expect(labOn("chatViewer")).toBe(true);
});

test("without an app choice, dev URL beats default and layout beats URL", async () => {
  dom.reconfigure({ url: "https://pane.test/?data-lab-chat-viewer=off" });
  const { configureLabs, labOn } = await load();
  expect(labOn("chatViewer")).toBe(false);
  configureLabs({ labs: { chatViewer: true } });
  expect(labOn("chatViewer")).toBe(true);
  configureLabs(undefined);
  expect(labOn("chatViewer")).toBe(false);
});

test("chatViewer defaults on after layout removal", async () => {
  const { LABS, configureLabs, labOn } = await load();
  expect(LABS).toEqual(["chatViewer"]);
  expect(labOn("chatViewer")).toBe(true);
  configureLabs({ labs: { chatViewer: false } });
  expect(labOn("chatViewer")).toBe(false);
  configureLabs({});
  expect(labOn("chatViewer")).toBe(true);
});
