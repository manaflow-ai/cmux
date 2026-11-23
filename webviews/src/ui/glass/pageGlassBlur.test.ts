// pageGlassBlur.ts: a menu or popover the App draws no glass under blurs the page under it in place
// (Leo 2026-11-22: "doubled up glass/wack looking glass all over the place"), and only then.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { coveredInPlace, installPageGlassBlur, pageBlursUnder, underBodyPortal } from "./pageGlassBlur";

let stop: (() => void) | undefined;
afterEach(() => stop?.());

/** A page with its root, and the blur's attach recorded instead of drawn. */
function page() {
  const dom = new JSDOM("<!doctype html><html><body><main id=root><p>line 1 of hosted</p></main></body></html>");
  const doc = dom.window.document;
  const attached: { surface: HTMLElement; covers: Element[] }[] = [];
  const detached: HTMLElement[] = [];
  stop = installPageGlassBlur(doc, (surface, candidates) => {
    attached.push({ surface, covers: [...candidates!(surface)] });
    return () => detached.push(surface);
  });
  /** Base UI's portal: a wrapper appended to <body>, then the menu inside it. */
  const open = async (attributes = "") => {
    const wrapper = doc.createElement("div");
    doc.body.append(wrapper);
    await tick();
    wrapper.innerHTML = `<div class="ui-positioner"><div class="ui-popup ui-glass ui-menu" data-host-glass="popover" data-host-glass-cover ${attributes}>Branch</div></div>`;
    await tick();
    return { wrapper, surface: wrapper.querySelector<HTMLElement>(".ui-popup")! };
  };
  return { doc, attached, detached, open };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a body-portalled menu the App does not draw blurs the page's root under it", async () => {
  const { doc, attached, open } = page();
  const { surface } = await open();
  expect(attached.map((entry) => entry.surface)).toEqual([surface]);
  expect(attached[0]!.covers).toEqual([doc.getElementById("root")!]);
});

test("a menu the App draws glass under is left to hostGlass.ts", async () => {
  const { attached, open } = page();
  await open(`data-host-glass-drawn="1"`);
  expect(attached).toEqual([]);
});

test("the App's glass arriving, a close starting and the portal going each take the blur away", async () => {
  const { attached, detached, open } = page();
  const first = await open();
  first.surface.setAttribute("data-host-glass-drawn", "1");
  await tick();
  expect(detached).toEqual([first.surface]);
  const second = await open();
  second.surface.setAttribute("data-ending-style", "");
  await tick();
  expect(detached).toEqual([first.surface, second.surface]);
  const third = await open();
  third.wrapper.remove();
  await tick();
  expect(detached).toEqual([first.surface, second.surface, third.surface]);
  expect(attached.length).toBe(3);
});

test("the page's own content is never treated as a popup, and never covers another popup", async () => {
  const { doc, attached, open } = page();
  // A cover surface inside the page's root (a popover portalled into a UiProvider container) is the
  // page's own reporter's (hostGlass.ts in the agent pane), not this one's.
  doc
    .getElementById("root")!
    .insertAdjacentHTML("beforeend", `<div class="ui-popup ui-glass" data-host-glass-cover></div>`);
  await tick();
  expect(attached).toEqual([]);
  const a = await open();
  const b = await open();
  expect(underBodyPortal(b.surface)).not.toContain(a.wrapper);
  expect(pageBlursUnder(b.surface)).toBe(true);
});

test("a page's own popup portalled straight into <body> (the diff toolbar's menus) blurs the root", async () => {
  const { doc, attached } = page();
  const menu = doc.createElement("div");
  menu.className = "toolbar-menu ui-popup ui-glass source-menu";
  doc.body.append(menu);
  await tick();
  expect(attached.map((entry) => entry.surface)).toEqual([menu]);
  expect(attached[0]!.covers).toEqual([doc.getElementById("root")!]);
});

test("a popup drawn in place covers the page beside it at every level, never itself or its own row", () => {
  const dom = new JSDOM(
    `<!doctype html><html><body><div id=root><aside id=files></aside><main id=diff><div id=pill><button id=more></button><div id=menu class="ui-popup ui-glass"></div></div><section id=lines></section></main></div><div id=portal><div class="ui-popup ui-glass"></div></div></body></html>`,
  );
  const doc = dom.window.document;
  const covered = [...coveredInPlace(doc.getElementById("menu")!)].map((element) => element.id);
  expect(covered).toEqual(["more", "lines", "files"]);
});
