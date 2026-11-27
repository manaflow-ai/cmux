import { createRoot, rowRenders } from "./support/rowRenders";
// l10n-allow-file: test fixture asks and chat names, not shipped UI.
// The header's Needs you list (needsYou/NeedsYou.tsx) draws only the rows in and near view once it
// is longer than WINDOW_FROM, and keeps what a person does with it:
// - mounted rows stay at the rows in view plus the overscan, the same at 1,000 and 10,000 asks;
// - one ask's change draws its row only; a scroll step of one row draws only the row it brings in;
//   moving a link's focus draws the two rows it moves between;
// - the row that has the keyboard stays drawn wherever the list scrolls, with focus in it;
// - a row scrolled away and back shows what it showed (expanded);
// - y with no row focused answers the list's top ask, drawn or not;
// - every row says its place (aria-posinset, aria-setsize).
// jsdom lays nothing out: the list is a 480 px viewport and each row 80 px (offsetHeight, which the
// window measures), and the scroll offset moves only when written.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { NeedsYouActions } from "../src/agent-session/acpmux/needsYou/needsYouModel";
import type { NeedsYouAnswer, NeedsYouItem } from "../src/agent-session/acpmux/needsYou/model";
import { settleReact } from "./support/domTeardown";

const VIEWPORT = 480;
const ROW = 80;
const OVERSCAN = 6;

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Node",
  "IS_REACT_ACT_ENVIRONMENT",
  "CSS",
] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
  CSS: { escape: (value: string) => value.replace(/["\\]/g, "\\$&") },
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent|FocusEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
const proto = dom.window.HTMLElement.prototype;
const isList = (element: HTMLElement) => element.classList.contains("acpmux-needs-you-list");
Object.defineProperty(proto, "offsetHeight", {
  configurable: true,
  get(this: HTMLElement) {
    return isList(this) ? VIEWPORT : this.hasAttribute("data-index") ? ROW : 0;
  },
});
Object.defineProperty(proto, "offsetWidth", {
  configurable: true,
  get(this: HTMLElement) {
    return isList(this) || this.hasAttribute("data-index") ? 360 : 0;
  },
});
const offsets = new WeakMap<object, number>();
Object.defineProperty(proto, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, Math.max(0, value));
  },
});
proto.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  const top = typeof options === "number" ? options : (options?.top ?? this.scrollTop);
  this.scrollTop = top;
  this.dispatchEvent(new dom.window.Event("scroll"));
} as HTMLElement["scrollTo"];
proto.scrollIntoView = () => {};
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { NeedsYouPanel } = await import("../src/agent-session/acpmux/needsYou/NeedsYou");

// One fixed time for every snapshot's asks, as acpmux reports them.
const ASKED = Date.now();
const askItems = (n: number, changed?: { index: number; ask: string }): NeedsYouItem[] =>
  Array.from({ length: n }, (_, index) => ({
    id: `acpmux:p${index}`,
    kind: "approval" as const,
    sessionId: `s${index}`,
    ask: changed?.index === index ? changed.ask : `Run step ${index}`,
    who: { name: `Chat ${index}`, harness: "claude", chief: false },
    at: ASKED - index * 60_000,
    answers: [
      { id: `p${index}-yes`, label: "Allow", tone: "allow" as const },
      { id: `p${index}-no`, label: "Deny", tone: "deny" as const },
    ],
    permissionId: `p${index}`,
  }));

async function mount(n: number) {
  const answered: string[] = [];
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const actions = (): NeedsYouActions => ({
    answer: async (item: NeedsYouItem, choice: NeedsYouAnswer) => {
      answered.push(`${item.id}:${choice.id}`);
      return new Promise(() => {});
    },
    goTo: () => {},
    ask: async () => undefined,
  });
  const draw = (items: NeedsYouItem[], focus?: string) =>
    act(async () => root.render(<NeedsYouPanel items={items} actions={actions()} focus={focus} />));
  await draw(askItems(n));
  const list = () => host.querySelector<HTMLElement>(".acpmux-needs-you-list")!;
  const drawn = () =>
    [...host.querySelectorAll<HTMLElement>(".acpmux-needs-you-slot")].map((slot) => Number(slot.dataset.index));
  const scrollTo = (top: number) =>
    act(async () => {
      list().scrollTop = top;
      list().dispatchEvent(new dom.window.Event("scroll"));
    });
  const unmount = async () => {
    await act(async () => root.unmount());
    host.remove();
  };
  return { host, draw, list, drawn, scrollTo, unmount, answered };
}

const MOST = Math.ceil(VIEWPORT / ROW) + 2 * OVERSCAN + 2;

test("mounted rows and DOM nodes stay at the window from 1,000 to 10,000 asks", async () => {
  const seen: { n: number; rows: number; nodes: number }[] = [];
  for (const n of [1_000, 10_000]) {
    const list = await mount(n);
    const rows = list.host.querySelectorAll(".acpmux-needs-you-item").length;
    const nodes = list.host.querySelectorAll("*").length;
    seen.push({ n, rows, nodes });
    console.log(`Needs you N=${n}: mounted rows ${rows}, DOM nodes ${nodes}`);
    await list.unmount();
  }
  for (const { rows } of seen) expect(rows).toBeLessThanOrEqual(MOST);
  expect(Math.abs(seen[1]!.nodes - seen[0]!.nodes) / seen[0]!.nodes).toBeLessThanOrEqual(0.1);
});

test("one ask's change, a scroll step and a focus move draw only the rows they change", async () => {
  const n = 1_000;
  const list = await mount(n);

  rowRenders.reset();
  await list.draw(askItems(n));
  const sameData = rowRenders.count("NeedsYouRow");

  rowRenders.reset();
  await list.draw(askItems(n, { index: 2, ask: "Run step two again" }));
  const oneChange = rowRenders.count("NeedsYouRow");
  expect(list.host.querySelector('[data-index="2"] .acpmux-needs-you-ask-toggle')?.textContent).toBe(
    "Run step two again",
  );

  // One row down: the rows the window adds draw, no other.
  const before = new Set(list.drawn());
  rowRenders.reset();
  await list.scrollTo(ROW);
  const scrollStep = rowRenders.count("NeedsYouRow");
  const entered = list.drawn().filter((index) => !before.has(index)).length;

  await list.draw(askItems(n, { index: 2, ask: "Run step two again" }), "acpmux:p3");
  rowRenders.reset();
  await list.draw(askItems(n, { index: 2, ask: "Run step two again" }), "acpmux:p5");
  const focusMove = rowRenders.count("NeedsYouRow");

  console.log(
    `NeedsYouRow renders (N=${n}): same data ${sameData}, one ask ${oneChange}, scroll step of one row ${scrollStep} (rows entering ${entered}), focus move ${focusMove}`,
  );
  expect(sameData).toBe(0);
  expect(oneChange).toBe(1);
  expect(scrollStep).toBe(entered);
  expect(entered).toBeLessThanOrEqual(1);
  expect(focusMove).toBe(2);
  await list.unmount();
});

test("the row with the keyboard stays drawn, a row keeps its stage, and rows say their place", async () => {
  const n = 1_000;
  const list = await mount(n);
  const slot = (index: number) => list.host.querySelector<HTMLElement>(`[data-index="${index}"]`);
  expect(slot(0)?.getAttribute("aria-posinset")).toBe("1");
  expect(slot(0)?.getAttribute("aria-setsize")).toBe(String(n));
  expect(list.list().getAttribute("role")).toBe("list");

  // Row 2 expanded, row 3's Allow has focus; the list scrolls far away.
  await act(async () => slot(2)!.querySelector<HTMLButtonElement>(".acpmux-needs-you-ask-toggle")!.click());
  expect(slot(2)?.querySelector(".acpmux-needs-you-item")?.getAttribute("data-stage")).toBe("expanded");
  const allow = slot(3)!.querySelector<HTMLButtonElement>('button[data-answer-key="y"]')!;
  await act(async () => allow.focus());
  await list.scrollTo(400 * ROW);
  expect(list.drawn()).toContain(3);
  expect(list.drawn()).not.toContain(2);
  expect(dom.window.document.activeElement).toBe(allow);
  expect(list.drawn().length).toBeLessThanOrEqual(MOST + 1);

  // Back at the top, row 2 is still expanded.
  await act(async () => list.host.querySelector<HTMLElement>(".acpmux-needs-you-panel")!.focus());
  await list.scrollTo(0);
  expect(slot(2)?.querySelector(".acpmux-needs-you-item")?.getAttribute("data-stage")).toBe("expanded");
  await list.unmount();
});

test("y on the list answers its top ask even when it is scrolled out of the window", async () => {
  const list = await mount(1_000);
  const panel = list.host.querySelector<HTMLElement>(".acpmux-needs-you-panel")!;
  await act(async () => panel.focus());
  await list.scrollTo(400 * ROW);
  expect(list.drawn()).not.toContain(0);
  await act(async () => {
    panel.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "y", bubbles: true, cancelable: true }));
  });
  expect(list.answered).toEqual(["acpmux:p0:p0-yes"]);
  await list.unmount();
});
