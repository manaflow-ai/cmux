// The sidebar's chat history page (src/pages/sidebar-chats) against its wire contract with the native
// host (SidebarChatHistoryHost.swift): it draws the block the host streams (Pinned or Earlier, the rows,
// Show More or Loading, the fold), sends each click with the revision it was made on, reports ready once
// per drawn revision with the height the host's layout reserves, and drops a stale or malformed block.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { teardownDom } from "./support/domTeardown";

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
let host: HTMLElement;
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
const { SidebarChatsOps, blockHeight, parseBlock, rowLabel } = await import("../src/pages/sidebar-chats/model");
const { FIXTURE_STRINGS, fixtureBlock, fixtureRows } = await import("../src/pages/sidebar-chats/fixtures");

type Call = { op: string; params: Record<string, unknown> };
const mounted: Array<{ unmount(): void }> = [];

async function mount() {
  host = view.document.createElement("div");
  view.document.body.replaceChildren(host);
  const calls: Call[] = [];
  let emit!: (block: unknown) => void;
  const frames: Array<() => void> = [];
  const client = {
    call: (op: string, params: Record<string, unknown>) => {
      calls.push({ op, params });
      return Promise.resolve(undefined);
    },
    subscribe: async (_stream: string, onEvent: (data: unknown) => void) => {
      emit = onEvent;
      return () => {};
    },
    handle: () => () => {},
  };
  let chats!: ReturnType<typeof mountSidebarChats>;
  await act(async () => {
    chats = mountSidebarChats(host, client as never, FIXTURE_STRINGS, {
      nextFrame: (run) => {
        frames.push(run);
        return () => {
          const at = frames.indexOf(run);
          if (at >= 0) frames.splice(at, 1);
        };
      },
    });
  });
  mounted.push(chats);
  return {
    chats,
    calls,
    of: (op: string) => calls.filter((call) => call.op === op).map((call) => call.params),
    send: (block: unknown) => act(async () => emit(block)),
    flushFrames: () => act(async () => frames.splice(0).forEach((run) => run())),
    click: (selector: string) =>
      act(async () => {
        host.querySelector(selector)!.dispatchEvent(new view.MouseEvent("click", { bubbles: true, button: 0 }));
      }),
    rightClick: (selector: string, x: number, y: number) =>
      act(async () => {
        host
          .querySelector(selector)!
          .dispatchEvent(
            new view.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: x, clientY: y }),
          );
      }),
    titles: () => [...host.querySelectorAll(".sc-row:not(.sc-tail) .sc-title")].map((node) => node.textContent),
  };
}

afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((chats) => chats.unmount()));
  view.document.body.replaceChildren();
});

test("nothing draws and nothing is sent before the host's first block", async () => {
  const page = await mount();
  await page.flushFrames();
  expect(host.querySelector(".sc-block")).toBeNull();
  expect(page.calls).toEqual([]);
});

test("Earlier draws its header, a row per chat and Show More, with the row's spoken name", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ rows: fixtureRows(3) }));
  expect(host.querySelector(".sc-header-name")?.textContent).toBe("Earlier");
  expect(host.querySelector(".sc-header")?.getAttribute("aria-expanded")).toBe("true");
  expect(page.titles()).toEqual(fixtureRows(3).map((row) => row.title));
  expect(host.querySelector(".sc-tail")?.textContent).toBe("Show More");
  const first = fixtureRows(1)[0]!;
  expect(host.querySelector(".sc-row")?.getAttribute("aria-label")).toBe(rowLabel(first));
  expect(rowLabel(first)).toBe(`${first.title}, ${first.harness}, ${first.meta}`);
  // Earlier's titles are the quiet ones.
  expect(host.querySelector(".sc-block")?.hasAttribute("data-quiet")).toBe(true);
});

test("Pinned has a header that does not fold, loud titles and no tail", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ part: "pinned", rows: fixtureRows(2), tail: null }));
  expect(host.querySelector(".sc-header-name")?.textContent).toBe("Pinned");
  expect(host.querySelector("button.sc-header")).toBeNull();
  expect(host.querySelector(".sc-tail")).toBeNull();
  expect(host.querySelector(".sc-block")?.hasAttribute("data-quiet")).toBe(false);
});

test("a folded Earlier keeps only its header; Loading shows until acpmux sends the rows", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ folded: true }));
  expect(page.titles()).toEqual([]);
  expect(host.querySelector(".sc-tail")).toBeNull();
  expect(host.querySelector(".sc-header")?.getAttribute("aria-expanded")).toBe("false");
  await page.send(fixtureBlock({ revision: 2, rows: [], tail: "loading" }));
  expect(host.querySelector(".sc-tail")?.textContent).toBe("Loading chats…");
  // The Loading row asks for no page.
  await page.click(".sc-tail");
  expect(page.of(SidebarChatsOps.more)).toEqual([]);
});

test("a click, the fold, Show More and a right click go to the host with the drawn revision", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ revision: 7, rows: fixtureRows(3) }));
  await page.click('[data-chat="chat-1"]');
  await page.click(".sc-header");
  await page.click(".sc-tail");
  await page.rightClick('[data-chat="chat-2"]', 40, 70);
  expect(page.calls.filter((call) => call.op !== SidebarChatsOps.ready)).toEqual([
    { op: SidebarChatsOps.open, params: { revision: 7, chat: "chat-1" } },
    { op: SidebarChatsOps.fold, params: { revision: 7 } },
    { op: SidebarChatsOps.more, params: { revision: 7 } },
    { op: SidebarChatsOps.menu, params: { revision: 7, chat: "chat-2", point: { x: 40, y: 70 } } },
  ]);
});

test("ready goes once per drawn revision with the block's height, and a newer block supersedes it", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ revision: 1 }));
  await page.send(fixtureBlock({ revision: 2, rows: fixtureRows(5) }));
  await page.flushFrames();
  expect(page.of(SidebarChatsOps.ready).map((call) => call.revision)).toEqual([2]);
  // The host's layout reserves exactly the drawn block (jsdom lays nothing out, so the style carries it).
  const block = fixtureBlock({ revision: 2, rows: fixtureRows(5) });
  expect((host.querySelector(".sc-block") as HTMLElement).style.height).toBe(`${blockHeight(block)}px`);
  expect(blockHeight(block)).toBe(28 + 6 * (28 + 2));
  expect(blockHeight(fixtureBlock({ folded: true }))).toBe(28);
});

test("a stale or malformed block changes nothing", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ revision: 5, rows: fixtureRows(2) }));
  await page.send(fixtureBlock({ revision: 4, rows: fixtureRows(6) }));
  expect(page.titles().length).toBe(2);
  await page.send({ revision: 9, part: "elsewhere", rows: [] });
  await page.send(null);
  expect(page.chats.block?.revision).toBe(5);
  expect(parseBlock({ ...fixtureBlock(), rows: [{ id: 1 }, { id: "a", title: "A" }] })?.rows).toEqual([
    { id: "a", title: "A" },
  ]);
});
