// The sidebar's chat history page draws again only the rows that changed. The host pushes a whole new
// block (fresh JSON, a new revision) on every change and on its age tick (SidebarChatHistoryHost.show,
// `now: Date()`), and dates each row's age itself (`meta`). So at 1,000 rows one changed row draws
// exactly one row, and a tick draws only the rows whose age label moved: none when no label moved.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { teardownDom } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Event",
  "MouseEvent",
  "MutationObserver",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let view: Window & typeof globalThis;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Event: window.Event,
    MouseEvent: window.MouseEvent,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  view = window as unknown as Window & typeof globalThis;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const { mountSidebarChats } = await import("../src/pages/sidebar-chats/mount");
const { FIXTURE_STRINGS, fixtureBlock, fixtureRows } = await import("../src/pages/sidebar-chats/fixtures");
type Block = ReturnType<typeof fixtureBlock>;

const mounted: Array<{ unmount(): void }> = [];
afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((chats) => chats.unmount()));
  view.document.body.replaceChildren();
});

async function mount(first: Block) {
  const host = view.document.createElement("div");
  view.document.body.replaceChildren(host);
  let chats!: ReturnType<typeof mountSidebarChats>;
  await act(async () => {
    chats = mountSidebarChats(host, null, FIXTURE_STRINGS, { nextFrame: () => () => {} });
  });
  mounted.push(chats);
  // As off the wire: every push is new objects, the unchanged rows too.
  const show = (block: Block) => act(async () => chats.show(JSON.parse(JSON.stringify(block)) as Block));
  await show(first);
  const rows = () => host.querySelectorAll(".sc-row[data-chat]");
  return { host, show, rows, renders: mountedRowRenders(rows) };
}

const N = 1_000;

test("at 1,000 rows one changed row draws exactly that row; an age tick draws only the rows whose age moved", async () => {
  const rows = fixtureRows(N);
  const page = await mount(fixtureBlock({ revision: 1, rows }));
  expect(page.rows().length).toBe(N);

  // One chat retitled.
  page.renders.mark();
  const retitled = rows.map((row, index) => (index === 500 ? { ...row, title: "Renamed" } : row));
  await page.show(fixtureBlock({ revision: 2, rows: retitled }));
  expect(page.host.querySelector('[data-chat="chat-500"] .sc-title')?.textContent).toBe("Renamed");
  expect(page.renders.since()).toBe(1);

  // The host's clock tick with no age label moved: nothing draws.
  page.renders.mark();
  await page.show(fixtureBlock({ revision: 3, rows: retitled }));
  expect(page.renders.since()).toBe(0);

  // A tick that moves one row's age ("2m" to "3m"): that row alone draws.
  page.renders.mark();
  const ticked = retitled.map((row, index) => (index === 0 ? { ...row, meta: "3m" } : row));
  await page.show(fixtureBlock({ revision: 4, rows: ticked }));
  expect(page.host.querySelector('[data-chat="chat-0"] .sc-meta')?.textContent).toBe("3m");
  expect(page.renders.since()).toBe(1);
});

test("Show More's next page mounts the new rows and draws none of the old ones again", async () => {
  const page = await mount(fixtureBlock({ revision: 1, rows: fixtureRows(20) }));
  page.renders.mark();
  await page.show(fixtureBlock({ revision: 2, rows: fixtureRows(40) }));
  expect(page.rows().length).toBe(40);
  // The 20 new rows mounted; the 20 already drawn did not draw again.
  expect(page.renders.since()).toBe(20);
});
