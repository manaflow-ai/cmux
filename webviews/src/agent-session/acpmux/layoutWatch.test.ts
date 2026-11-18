// The layout watch on a New Tab page (layoutWatch.ts). That page has no composer and no transcript rows,
// so the watch names the page's own parts, takes the first frame that has its box and its field as the
// first paint, and reports a part that moves or comes after that frame. The frames and the clock are the
// test's: one frame is one call of the watch's requestAnimationFrame, 10 ms apart.
import { afterAll, afterEach, beforeAll, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";
import { layoutWatch } from "./layoutWatch";

type Box = { x: number; y: number; w: number; h: number };
type Shift = { element: string; at_ms: number; from: Box; to: Box };
type Appeared = { element: string; at_ms: number; box: Box };

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const doc = dom.window.document;
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document", "requestAnimationFrame"] as const).map(
  (key) => [key, key in scope, scope[key]] as const,
);

let clock = 0;
let frame = 0;
/// What the page does before the watch reads frame `index` (the first read is frame 0).
let before: (index: number) => void = () => {};
const now = spyOn(performance, "now").mockImplementation(() => clock);

beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: doc,
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      frame += 1;
      clock += 10;
      before(frame);
      queueMicrotask(() => callback(clock));
      return frame;
    },
  });
  // jsdom lays nothing out: the watch's empty-chat check reads the body's text.
  Object.defineProperty(doc.body, "innerText", { get: () => doc.body.textContent, configurable: true });
});
afterEach(() => {
  doc.body.replaceChildren();
  before = () => {};
});
afterAll(async () => {
  now.mockRestore();
  await teardownDom(saved, { window: dom.window });
});

/// Gives `node` a box, as a layout would.
function place(node: Element, x: number, y: number, w: number, h: number) {
  node.getBoundingClientRect = () =>
    ({ x, y, width: w, height: h, left: x, top: y, right: x + w, bottom: y + h }) as DOMRect;
}

/// A New Tab page with the classes that NewTabPage.tsx gives its parts, each with a box, the field aside:
/// `field()` places it (the editor mounts after the page's first render).
function newTabPage() {
  doc.body.innerHTML = `
    <div class="acpmux-newtab"><div class="acpmux-newtab-anchor">
      <form class="acpmux-newtab-box">
        <div class="acpmux-newtab-row">
          <div class="acpmux-newtab-field">Ask anything</div>
          <fieldset class="acpmux-newtab-switch">
            <button class="acpmux-newtab-kind is-selected">Agent</button>
            <button class="acpmux-newtab-kind">Terminal</button>
            <button class="acpmux-newtab-kind">Browser</button>
          </fieldset>
        </div>
        <div class="acpmux-newtab-under">
          <span class="acpmux-newtab-context"><button class="acpmux-project-button">cmux</button><span class="acpmux-newtab-chip">Agent</span></span>
          <button class="acpmux-send">Open</button>
        </div>
      </form>
      <div class="acpmux-newtab-foot"><button data-menu="Model">Model</button></div>
    </div><div class="acpmux-newtab-actions"><button class="acpmux-newtab-all">All sessions</button></div></div>`;
  const part = (selector: string, index = 0) => doc.querySelectorAll(selector)[index]!;
  place(part(".acpmux-newtab"), 0, 0, 800, 600);
  place(part(".acpmux-newtab-box"), 100, 200, 600, 96);
  place(part(".acpmux-newtab-row"), 108, 208, 584, 40);
  place(part(".acpmux-newtab-switch"), 500, 212, 188, 32);
  for (const index of [0, 1, 2]) place(part(".acpmux-newtab-kind", index), 500 + index * 62, 212, 60, 32);
  place(part(".acpmux-newtab-under"), 108, 252, 584, 36);
  place(part(".acpmux-newtab-context"), 108, 256, 300, 28);
  place(part(".acpmux-project-button"), 108, 256, 90, 28);
  place(part(".acpmux-newtab-chip"), 204, 256, 70, 28);
  place(part(".acpmux-send"), 660, 256, 28, 28);
  place(part(".acpmux-newtab-foot"), 100, 304, 600, 28);
  place(part("button[data-menu=Model]"), 100, 304, 80, 28);
  place(part(".acpmux-newtab-actions"), 100, 560, 600, 32);
  place(part(".acpmux-newtab-all"), 100, 560, 120, 32);
  return { part, field: (y = 208) => place(part(".acpmux-newtab-field"), 140, y, 350, 40) };
}

async function watch() {
  clock = 0;
  frame = 0;
  return (await layoutWatch({ ms: 100 })) as {
    frames: number;
    first_content_ms: number | null;
    first_rows: number;
    elements?: number;
    new_tab?: Record<string, Box> | null;
    shifts: Shift[];
    appeared: Appeared[];
  };
}

test("a New Tab page that is drawn at the first frame and stays is its first paint, with no change", async () => {
  newTabPage().field();
  const report = await watch();
  expect(report.frames).toBe(10);
  expect(report.first_content_ms).toBe(0);
  expect(report.first_rows).toBe(0);
  // The page, its box, row, field, switch, 3 kinds, the line under them, its context, the project's chip, 1
  // chip, the send button, the footer, the actions and their button, and the footer's menu chip.
  expect(report.elements).toBe(17);
  expect(Object.keys(report.new_tab ?? {}).sort()).toEqual([
    "chip:Model",
    "newtab",
    "newtab-actions",
    "newtab-all",
    "newtab-box",
    "newtab-chip",
    "newtab-context",
    "newtab-field",
    "newtab-foot",
    "newtab-kind",
    "newtab-kind:1",
    "newtab-kind:2",
    "newtab-row",
    "newtab-switch",
    "newtab-under",
    "project-button",
    "send",
  ]);
  expect(report.new_tab?.["newtab-box"]).toEqual({ x: 100, y: 200, w: 600, h: 96 });
  expect(report.new_tab?.["newtab-field"]).toEqual({ x: 140, y: 208, w: 350, h: 40 });
  expect(report.shifts).toEqual([]);
  expect(report.appeared).toEqual([]);
});

test("a chat's page has its first paint as before, and no New Tab parts", async () => {
  doc.body.innerHTML = `<header>Title</header><p>No messages</p><form class="acpmux-composer"><button class="acpmux-send">Send</button></form>`;
  place(doc.querySelector("header")!, 0, 0, 800, 40);
  place(doc.querySelector(".acpmux-composer")!, 100, 500, 600, 80);
  place(doc.querySelector(".acpmux-send")!, 660, 540, 28, 28);
  const report = await watch();
  expect(report.first_content_ms).toBe(0);
  // The composer and the header: a class of the New Tab page's list is read inside a New Tab page only.
  expect(report.elements).toBe(2);
  expect(report.new_tab ?? null).toBeNull();
});

test("the first paint of a New Tab page is the frame that has its field", async () => {
  const page = newTabPage();
  before = (index) => {
    if (index === 3) page.field();
  };
  const report = await watch();
  expect(report.first_content_ms).toBe(30);
  expect(report.appeared).toEqual([]);
});

test("a part that moves after the first paint is a shift, by its name, with both boxes", async () => {
  const page = newTabPage();
  page.field();
  before = (index) => {
    // The line under the field goes 4 px down in frame 4, and the second kind grows 6 px in frame 6.
    if (index === 4) place(page.part(".acpmux-newtab-under"), 108, 256, 584, 36);
    if (index === 6) place(page.part(".acpmux-newtab-kind", 1), 562, 212, 66, 32);
  };
  const report = await watch();
  expect(report.first_content_ms).toBe(0);
  expect(report.shifts).toEqual([
    {
      element: "newtab-under",
      at_ms: 40,
      from: { x: 108, y: 252, w: 584, h: 36 },
      to: { x: 108, y: 256, w: 584, h: 36 },
    },
    {
      element: "newtab-kind:1",
      at_ms: 60,
      from: { x: 562, y: 212, w: 60, h: 32 },
      to: { x: 562, y: 212, w: 66, h: 32 },
    },
  ]);
});

test("a part that comes after the first paint is named with its frame", async () => {
  const page = newTabPage();
  page.field();
  const foot = page.part(".acpmux-newtab-foot");
  foot.remove();
  before = (index) => {
    if (index === 5) page.part(".acpmux-newtab-anchor").append(foot);
  };
  const report = await watch();
  expect(report.elements).toBe(15);
  expect(report.appeared).toEqual([
    { element: "chip:Model", at_ms: 50, box: { x: 100, y: 304, w: 80, h: 28 } },
    { element: "newtab-foot", at_ms: 50, box: { x: 100, y: 304, w: 600, h: 28 } },
  ]);
});

test("a page with no New Tab page and no composer has no first paint", async () => {
  doc.body.innerHTML = "<main>Loading</main>";
  const report = await watch();
  expect(report.first_content_ms).toBeNull();
  expect(report.shifts).toEqual([]);
});

test("each class of this test's page is a class in the New Tab page's markup", () => {
  // NewTabPage.tsx and its project chip name their parts by class; a renamed class there would leave the
  // watch blind to that part while the tests above stay green on their own page.
  const page = ["./NewTabPage.tsx", "./ProjectChooser.tsx"]
    .map((file) => readFileSync(new URL(file, import.meta.url), "utf8"))
    .join("\n");
  const classes = [...newTabPageClasses()];
  expect(classes.length).toBe(15);
  // The whole name: `acpmux-newtab` is not found in `acpmux-newtab-box`.
  for (const name of classes) expect(page).toMatch(new RegExp(`(?<![\\w-])${name}(?![\\w-])`));
});

/// The `acpmux-` classes of this test's page.
function newTabPageClasses(): Set<string> {
  newTabPage();
  const names = new Set<string>();
  for (const node of doc.querySelectorAll("[class]"))
    for (const name of node.classList) if (name.startsWith("acpmux-")) names.add(name);
  return names;
}
