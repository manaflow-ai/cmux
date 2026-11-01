// The default New Tab is calm (Leo 2026-10-11, "why is the default new tab showing all this
// stuff"): the composer, then at most five recent chats as quiet rows with "All Chats" for the
// rest. No tools row, no Recently Closed, no All chats table. Its send control is a real button,
// the composer's arrow-up disc: off while the field is empty, filled once there is text.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    // The suggestions' Popover (Base UI and Floating UI) reads Element and Node (Node below).
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    // The field is the composer's Markdown field (ProseMirror).
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

test("the default New Tab shows the composer and five recent chats, nothing else", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  let showAll = 0;
  try {
    await act(async () =>
      root.render(
        <NewTabScreen
          snapshot={noChat(manySessions(12))}
          lastAgent="claude"
          loadChatsPage={async () => ({ ready: true, chats: [] })}
          onOpenChat={noop}
          onAsk={noop}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
          onOpenSession={noop}
          onShowAll={() => (showAll += 1)}
        />,
      ),
    );
    const page = {
      tools: host.querySelectorAll(".nt-tools").length,
      closed: host.querySelectorAll(".nt-closed").length,
      allChatsTable: host.querySelectorAll(".nt-all").length,
      chats: host.querySelectorAll(".nt-cards[data-variant=list] .nt-card").length,
    };
    expect(page).toEqual({ tools: 0, closed: 0, allChatsTable: 0, chats: 5 });
    await act(async () => host.querySelector<HTMLButtonElement>(".nt-chats-all")!.click());
    expect(showAll).toBe(1);

    const send = host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!;
    const look = () => ({
      disc: send.classList.contains("acpmux-send"),
      ready: send.classList.contains("acpmux-send-ready"),
      disabled: send.disabled,
      arrow: send.querySelector("svg") !== null,
      text: send.textContent,
      title: send.title,
    });
    expect(look()).toEqual({
      disc: true,
      ready: false,
      disabled: true,
      arrow: true,
      text: "",
      title: "Send (Return)",
    });
    const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
    for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    const handle = field.acpmuxMarkdownField!;
    await act(async () => {
      handle.focus();
      handle.type("fix the flaky upload test");
    });
    expect(handle.value()).toBe("fix the flaky upload test");
    expect(look()).toMatchObject({ ready: true, disabled: false });
  } finally {
    await act(async () => root.unmount());
  }
});
