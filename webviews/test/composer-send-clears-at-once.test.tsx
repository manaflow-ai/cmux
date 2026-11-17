// Send clears the composer at once, also for a send the host takes later (a View Only chat, the Quick
// Composer, a fork onto a held model): no "Still sending your last message" guard holds the prompt or
// refuses the next Return. A prompt sent meanwhile goes after the first, in order. A refused send comes
// back: as it was into an empty composer, else after what was written since, so nothing is lost
// (Leo 2026-11-17: "remove bullshit ceremony + bullshit text + bullshit belt and suspenders").
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "InputEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

let chats = 0;
function chat(): AcpmuxSnapshot {
  const sessionId = `send-at-once-${++chats}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
  });
}

/** One send the host has not answered: `take` or `refuse` settles it. */
type Pending = { text: string; take(): void; refuse(): void };

/** The composer over a chat whose host takes each prompt later (onSend answers a promise). */
async function composer() {
  const asked: Pending[] = [];
  let handle: ComposerHandle | null = null;
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const snapshot = chat();
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        sessionId={snapshot.sessionId}
        chips={Chips}
        onSend={(text) =>
          new Promise<void>((resolve, reject) => {
            asked.push({ text, take: resolve, refuse: () => reject(new Error("refused")) });
          })
        }
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  const type = (text: string) => act(async () => handle!.restore(text, []));
  const enter = () =>
    act(async () => {
      field.dispatchEvent(
        new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Enter", keyCode: 13 }),
      );
    });
  const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return { field, asked, type, enter, settle };
}

const stillSending = "Still sending your last message";

test("Send clears the composer at once, before the host takes the prompt", async () => {
  const page = await composer();
  await page.type("ship it");
  await page.enter();
  expect(page.asked.map((send) => send.text)).toEqual(["ship it"]);
  expect(page.field.textContent).toBe("");
  expect(host.textContent).not.toContain(stillSending);
  await act(async () => page.asked[0]!.take());
  await page.settle();
  expect(page.field.textContent).toBe("");
});

test("a second prompt sent while the first is still going is taken, and goes after it in order", async () => {
  const page = await composer();
  await page.type("first");
  await page.enter();
  await page.type("second");
  await page.enter();
  // No guard: the second leaves the composer too, and no note says the first is still going.
  expect(page.field.textContent).toBe("");
  expect(host.textContent).not.toContain(stillSending);
  // It waits for the first, so the host never gets them out of order.
  expect(page.asked.map((send) => send.text)).toEqual(["first"]);
  await act(async () => page.asked[0]!.take());
  await page.settle();
  expect(page.asked.map((send) => send.text)).toEqual(["first", "second"]);
  await page.type("third");
  await page.enter();
  // The second is still going: the third waits behind it.
  expect(page.asked.map((send) => send.text)).toEqual(["first", "second"]);
  await act(async () => page.asked[1]!.take());
  await page.settle();
  expect(page.asked.map((send) => send.text)).toEqual(["first", "second", "third"]);
});

test("a refused send comes back into the empty composer", async () => {
  const page = await composer();
  await page.type("ship it");
  await page.enter();
  expect(page.field.textContent).toBe("");
  await act(async () => page.asked[0]!.refuse());
  await page.settle();
  expect(page.field.textContent).toBe("ship it");
});

test("a refused send never overwrites what was typed since: it comes back after it", async () => {
  const page = await composer();
  await page.type("ship it");
  await page.enter();
  await page.type("and the docs");
  await act(async () => page.asked[0]!.refuse());
  await page.settle();
  const shown = page.field.textContent ?? "";
  expect(shown).toContain("and the docs");
  expect(shown).toContain("ship it");
  expect(shown.indexOf("and the docs")).toBeLessThan(shown.indexOf("ship it"));
});

test("the guard's sentence is gone from the catalog, in every language", async () => {
  const catalog = await Bun.file(
    new URL("../src/agent-session/acpmux/Localizable.xcstrings", import.meta.url).pathname,
  ).json();
  expect(Object.keys(catalog.strings)).not.toContain("composer.stillSending");
});
