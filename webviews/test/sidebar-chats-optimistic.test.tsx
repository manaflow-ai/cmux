// The sidebar chat history page draws Earlier's fold and Show More at the click, before the host answers
// (optimistic): the host's block replaces the drawn guess when it answers, and a refused call takes it back.
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
const { SidebarChatsOps, blockHeight } = await import("../src/pages/sidebar-chats/model");
const { FIXTURE_STRINGS, fixtureBlock, fixtureRows } = await import("../src/pages/sidebar-chats/fixtures");

type Reply = { op: string; params: Record<string, unknown>; resolve(): void; reject(error: Error): void };
const mounted: Array<{ unmount(): void }> = [];

/** The page on a host whose fold and Show More answer only when the test says so. */
async function mount() {
  host = view.document.createElement("div");
  view.document.body.replaceChildren(host);
  const replies: Reply[] = [];
  const streams = new Map<string, (data: unknown) => void>();
  const frames: Array<() => void> = [];
  const client = {
    call: (op: string, params: Record<string, unknown>) =>
      op === SidebarChatsOps.fold || op === SidebarChatsOps.more
        ? new Promise<void>((resolve, reject) => replies.push({ op, params, resolve, reject }))
        : Promise.resolve(undefined).then(() => void replies.push({ op, params, resolve() {}, reject() {} })),
    subscribe: async (stream: string, onEvent: (data: unknown) => void) => {
      streams.set(stream, onEvent);
      return () => {};
    },
    handle: () => () => {},
  };
  let chats!: ReturnType<typeof mountSidebarChats>;
  await act(async () => {
    chats = mountSidebarChats(host, client as never, FIXTURE_STRINGS, {
      nextFrame: (run) => {
        frames.push(run);
        return () => frames.splice(frames.indexOf(run), 1);
      },
    });
  });
  mounted.push(chats);
  const reply = (op: string) => [...replies].reverse().find((entry) => entry.op === op)!;
  return {
    replies,
    send: (block: unknown) => act(async () => streams.get(SidebarChatsOps.block)?.(block)),
    answer: (op: string) => act(async () => reply(op).resolve()),
    refuse: (op: string) => act(async () => reply(op).reject(new Error("refused"))),
    flushFrames: () => act(async () => frames.splice(0).forEach((run) => run())),
    click: (selector: string) =>
      act(async () => {
        host.querySelector(selector)!.dispatchEvent(new view.MouseEvent("click", { bubbles: true, button: 0 }));
      }),
    expanded: () => host.querySelector(".sc-header")?.getAttribute("aria-expanded"),
    rows: () => host.querySelectorAll(".sc-row[data-chat]").length,
    tail: () => host.querySelector(".sc-tail")?.getAttribute("data-tail") ?? null,
  };
}

afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((chats) => chats.unmount()));
  view.document.body.replaceChildren();
});

test("a fold draws at the click, and the host's folded block keeps it", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ revision: 1, rows: fixtureRows(5) }));
  await page.click(".sc-header");
  // No answer yet: only the header, its chevron closed.
  expect(page.expanded()).toBe("false");
  expect(page.rows()).toBe(0);
  expect(page.tail()).toBeNull();
  expect(page.replies.map((entry) => entry.params)).toEqual([{ revision: 1 }]);
  // The host's age tick before its answer does not undo the fold.
  await page.send(fixtureBlock({ revision: 2, rows: fixtureRows(5) }));
  expect(page.expanded()).toBe("false");
  await page.send(fixtureBlock({ revision: 3, folded: true, rows: [], tail: null }));
  await page.answer(SidebarChatsOps.fold);
  expect(page.expanded()).toBe("false");
  expect(page.rows()).toBe(0);
});

test("an unfold draws the rows Earlier last listed at the click, then the host's own", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ revision: 1, rows: fixtureRows(4) }));
  await page.send(fixtureBlock({ revision: 2, folded: true, rows: [], tail: null }));
  expect(page.rows()).toBe(0);
  await page.click(".sc-header");
  expect(page.expanded()).toBe("true");
  expect(page.rows()).toBe(4);
  expect(page.tail()).toBe("more");
  await page.answer(SidebarChatsOps.fold);
  await page.send(fixtureBlock({ revision: 3, rows: fixtureRows(6) }));
  expect(page.rows()).toBe(6);
});

test("a refused fold takes the drawn fold back", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ revision: 1, rows: fixtureRows(3) }));
  await page.click(".sc-header");
  expect(page.rows()).toBe(0);
  await page.refuse(SidebarChatsOps.fold);
  expect(page.expanded()).toBe("true");
  expect(page.rows()).toBe(3);
});

test("Show More reads Loading at the click until the next chats come; a refusal takes it back", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ revision: 1, rows: fixtureRows(3) }));
  await page.click(".sc-tail");
  expect(page.tail()).toBe("loading");
  expect(host.querySelector(".sc-tail")?.textContent).toBe(FIXTURE_STRINGS.loading);
  await page.send(fixtureBlock({ revision: 2, rows: fixtureRows(6) }));
  expect(page.tail()).toBe("more");
  expect(page.rows()).toBe(6);
  await page.click(".sc-tail");
  expect(page.tail()).toBe("loading");
  await page.refuse(SidebarChatsOps.more);
  expect(page.tail()).toBe("more");
  expect(page.rows()).toBe(6);
});

test("a host that answers with the same rows ends Loading on its next block", async () => {
  const page = await mount();
  await page.send(fixtureBlock({ revision: 1, rows: fixtureRows(3) }));
  await page.click(".sc-tail");
  await page.answer(SidebarChatsOps.more);
  expect(page.tail()).toBe("loading");
  await page.send(fixtureBlock({ revision: 2, rows: fixtureRows(3) }));
  expect(page.tail()).toBe("more");
});

test("ready reports the host's revision at its own height while a fold waits", async () => {
  const page = await mount();
  const block = fixtureBlock({ revision: 1, rows: fixtureRows(5) });
  await page.send(block);
  await page.click(".sc-header");
  await page.flushFrames();
  const ready = page.replies.filter((entry) => entry.op === SidebarChatsOps.ready).map((entry) => entry.params);
  expect(ready).toEqual([{ revision: 1, height: blockHeight(block) }]);
});
