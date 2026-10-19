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
  document.documentElement.setAttribute("data-lab-live-render", "off");
  dom.reconfigure({ url: "https://pane.test/?data-lab-live-render=on" });
  const { configureLabs, labOn } = await load();
  expect(labOn("liveRender")).toBe(false);
  for (const layout of [undefined, {}, { labs: {} }, { labs: { liveRender: "on" } }]) {
    configureLabs(layout);
    expect(labOn("liveRender")).toBe(false);
    expect(document.documentElement.getAttribute("data-lab-live-render")).toBe("off");
  }
});

test("layout beats app off, and removing its entry restores the captured app value", async () => {
  document.documentElement.setAttribute("data-lab-live-render", "off");
  const { configureLabs, labOn } = await load();
  configureLabs({ labs: { liveRender: true } });
  expect(labOn("liveRender")).toBe(true);
  expect(document.documentElement.getAttribute("data-lab-live-render")).toBe("on");
  configureLabs({ labs: {} });
  expect(labOn("liveRender")).toBe(false);
  expect(document.documentElement.getAttribute("data-lab-live-render")).toBe("off");
  configureLabs({ labs: { liveRender: true } });
  configureLabs(undefined);
  expect(labOn("liveRender")).toBe(false);
});

test("layout false beats app on and removing the layout restores on", async () => {
  document.documentElement.setAttribute("data-lab-context-meter", "on");
  const { configureLabs, labOn } = await load();
  configureLabs({ labs: { contextMeter: false } });
  expect(labOn("contextMeter")).toBe(false);
  configureLabs({});
  expect(labOn("contextMeter")).toBe(true);
});

test("without app values, dev URLs beat defaults and layout beats dev URLs", async () => {
  dom.reconfigure({ url: "https://pane.test/?data-lab-live-render=off&data-lab-code-wrap=on" });
  const { configureLabs, labOn } = await load();
  configureLabs({ labs: {} });
  expect(labOn("liveRender")).toBe(false);
  expect(labOn("codeWrap")).toBe(true);
  configureLabs({ labs: { liveRender: true, codeWrap: false } });
  expect(labOn("liveRender")).toBe(true);
  expect(labOn("codeWrap")).toBe(false);
  configureLabs(undefined);
  expect(labOn("liveRender")).toBe(false);
  expect(labOn("codeWrap")).toBe(true);
});

test("with nothing set liveRender and renderGuide default on, even after layout removal", async () => {
  const { LABS, configureLabs, labOn } = await load();
  const defaultsOn = new Set([
    "liveRender",
    "renderGuide",
    "renderKit",
    "renderPreview",
    "renderExpand",
    "tableScroll",
    "chatViewer",
    "sourceIcons",
  ]);
  for (const lab of LABS) expect(labOn(lab)).toBe(defaultsOn.has(lab));
  configureLabs({ labs: Object.fromEntries(LABS.map((lab) => [lab, !defaultsOn.has(lab)])) });
  configureLabs({});
  for (const lab of LABS) {
    expect(labOn(lab)).toBe(defaultsOn.has(lab));
    const name = lab.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
    expect(document.documentElement.getAttribute(`data-lab-${name}`)).toBe(defaultsOn.has(lab) ? "on" : "off");
  }
});
