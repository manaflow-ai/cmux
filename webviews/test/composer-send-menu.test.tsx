// Send's menu (composer/SendMenu.tsx): a right-click or a long press on the composer's Send lists
// the ways the draft can go, Send, Queue for later and Send in side chat, each with the key that
// sends it that way from the prompt. Each row runs the composer's own path for it: Send as the
// button sends, Queue for later as ⌘Return queues behind a running turn, Send in side chat as
// `/side <prompt>` forks the chat. A way the chat cannot take now has no row. A long press opens the
// menu and does not send; a click still sends.
import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { CmuxCommand, CmuxCommandResult } from "../src/agent-session/acpmux/cmuxCommands";
import { LONG_PRESS_MS } from "../src/agent-session/acpmux/composer/SendMenu";
import { SEND_KEYS, sendChoiceForKey, type SendChoice } from "../src/agent-session/acpmux/composer/sendMenuModel";
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
  "MouseEvent",
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
    MouseEvent: window.MouseEvent,
    InputEvent: window.InputEvent,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  document.body.querySelectorAll(".ui-context-menu-backdrop").forEach((node) => node.remove());
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

type Sent = { text: string; steer?: boolean };

// Each test is its own chat, so no draft kept for one chat comes back in the next test.
let chats = 0;

function idle(): AcpmuxSnapshot {
  const sessionId = `send-menu-${++chats}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1, steering: true },
    rows: [user("Add retries", 1)],
    canFork: true,
  });
}

/** A turn runs, with an agent that takes Return into it: Send steers, ⌘Return queues. */
function working(): AcpmuxSnapshot {
  return { ...idle(), isWorking: true };
}

/** Renders the composer over `snapshot` with `typed` in the prompt; `side`: `/side` can fork it. */
async function composer(snapshot: AcpmuxSnapshot, typed: string, side = true) {
  const sent: Sent[] = [];
  const commands: { command: string; args?: string }[] = [];
  let handle: ComposerHandle | null = null;
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        sessionId={snapshot.sessionId}
        chips={Chips}
        onSend={(text, _attachments, steer) => {
          sent.push({ text, steer });
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        onCmuxCommand={(command: CmuxCommand, args?: string): CmuxCommandResult => {
          commands.push({ command: command.name, args });
          return true;
        }}
        sendsToSide={side}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  const send = () => host.querySelector<HTMLButtonElement>("button.acpmux-send")!;
  return { field, send, sent, commands };
}

/** Right-clicks Send, as the pointer's secondary button does. */
async function rightClick(button: HTMLElement) {
  const box = button.getBoundingClientRect();
  await act(async () => {
    button.dispatchEvent(
      new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left, clientY: box.top }),
    );
  });
}

const menu = () => document.querySelector<HTMLElement>('[role="menu"]');
/** Each row's name and the key it draws. */
const rows = () =>
  [...(menu()?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])].map((row) => ({
    label: row.getAttribute("aria-label"),
    key: row.querySelector(".ui-menu-shortcut")?.textContent,
  }));
const row = (label: string) =>
  [...(menu()?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])].find(
    (item) => item.getAttribute("aria-label") === label,
  )!;

const key = (choice: SendChoice) =>
  new window.KeyboardEvent("keydown", {
    key: "Enter",
    keyCode: 13,
    bubbles: true,
    cancelable: true,
    metaKey: SEND_KEYS[choice].meta,
    altKey: SEND_KEYS[choice].alt,
  });

test("a right-click on Send while a turn runs lists Send, Queue for later and Send in side chat with their keys", async () => {
  const { send, sent } = await composer(working(), "Also cover the timeout path");
  await rightClick(send());
  expect(rows()).toEqual([
    { label: "Send", key: "↩" },
    { label: "Queue for later", key: "⌘↩" },
    { label: "Send in side chat", key: "⌥↩" },
  ]);
  expect(sent).toEqual([]);
});

test("an idle chat has no Queue for later: Send already sends at once", async () => {
  const { send } = await composer(idle(), "Add retries");
  await rightClick(send());
  expect(rows().map((each) => each.label)).toEqual(["Send", "Send in side chat"]);
});

test("a chat that cannot fork has no Send in side chat row, never a disabled one", async () => {
  const { send } = await composer(working(), "Also cover the timeout path", false);
  await rightClick(send());
  expect(rows().map((each) => each.label)).toEqual(["Send", "Queue for later"]);
  expect(menu()?.querySelector("[disabled]")).toBeNull();
});

test("with Send its only way, a right-click opens no send menu", async () => {
  const { send } = await composer(idle(), "Add retries", false);
  await rightClick(send());
  expect(menu()?.querySelector('[aria-label="Send"]') ?? null).toBeNull();
});

test("Send steers the running turn, as the button does", async () => {
  const { send, sent } = await composer(working(), "Also cover the timeout path");
  await rightClick(send());
  await act(async () => row("Send").click());
  expect(sent).toEqual([{ text: "Also cover the timeout path", steer: true }]);
  expect(menu()).toBeNull();
});

// The slot's rules and the gallery read Send's place (`.acpmux-composer-actions > .acpmux-send +
// .acpmux-fit-mic`): the menu adds nothing around Send or after it. (This test's chat has no mic.)
test("the menu draws no element around Send or after it: Send stays the action slot's own child", async () => {
  const { send } = await composer(working(), "Also cover the timeout path");
  expect(send().parentElement?.classList.contains("acpmux-composer-actions")).toBe(true);
  expect(send().nextElementSibling).toBeNull();
});

test("Queue for later queues the prompt behind the turn, as ⌘Return does", async () => {
  const { send, sent } = await composer(working(), "Also cover the timeout path");
  await rightClick(send());
  await act(async () => row("Queue for later").click());
  expect(sent).toEqual([{ text: "Also cover the timeout path", steer: false }]);
  expect(menu()).toBeNull();
});

test("Send in side chat runs /side with the draft as its prompt and sends nothing here", async () => {
  const { send, sent, commands } = await composer(working(), "Try the other parser");
  await rightClick(send());
  await act(async () => row("Send in side chat").click());
  expect(commands).toEqual([{ command: "side", args: "Try the other parser" }]);
  expect(sent).toEqual([]);
});

test("a long press on Send opens the menu and its release does not send", async () => {
  const { send, sent } = await composer(working(), "Also cover the timeout path");
  const button = send();
  jest.useFakeTimers();
  try {
    await act(async () => {
      button.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
    });
    await act(async () => void jest.advanceTimersByTime(LONG_PRESS_MS - 1));
    expect(menu()).toBeNull();
    await act(async () => void jest.advanceTimersByTime(1));
  } finally {
    jest.useRealTimers();
  }
  expect(rows().map((each) => each.label)).toEqual(["Send", "Queue for later", "Send in side chat"]);
  await act(async () => {
    button.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true, button: 0 }));
    button.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, detail: 1 }));
  });
  expect(sent).toEqual([]);
});

test("a click on Send still sends at once, with no menu", async () => {
  const { send, sent } = await composer(working(), "Also cover the timeout path");
  const button = send();
  await act(async () => {
    button.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
    button.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true, button: 0 }));
    button.click();
  });
  expect(sent).toEqual([{ text: "Also cover the timeout path", steer: true }]);
  expect(menu()).toBeNull();
});

test("each row's key, pressed in the prompt, sends that way", async () => {
  const steer = await composer(working(), "now");
  await act(async () => void steer.field.dispatchEvent(key("send")));
  expect(steer.sent).toEqual([{ text: "now", steer: true }]);
  act(() => root?.unmount());
  root = undefined;

  const queue = await composer(working(), "later");
  await act(async () => void queue.field.dispatchEvent(key("queue")));
  expect(queue.sent).toEqual([{ text: "later", steer: false }]);
  act(() => root?.unmount());
  root = undefined;

  const side = await composer(working(), "elsewhere");
  await act(async () => void side.field.dispatchEvent(key("side")));
  expect(side.commands).toEqual([{ command: "side", args: "elsewhere" }]);
  expect(side.sent).toEqual([]);
});

test("Option-Return sends no side chat where the chat cannot fork", async () => {
  const { field, commands } = await composer(working(), "elsewhere", false);
  await act(async () => void field.dispatchEvent(key("side")));
  expect(commands).toEqual([]);
});

test("the menu's keys are Return forms the app leaves to the composer, read back as the same way", () => {
  // KeyBindingDefaults.textInputKeys, as the action catalog exports it: no app binding takes these
  // from a focused prompt, so the keys drawn on the rows are free there.
  const catalog = JSON.parse(readFileSync(join(import.meta.dir, "../../plans/cmux-next/action-catalog.json"), "utf8"));
  const textInput = (catalog.key_binding_defaults.text_input_keys as { key: string; modifiers: string[] }[]).map(
    (each) => `${[...each.modifiers].sort().join("+")}|${each.key}`,
  );
  for (const choice of Object.keys(SEND_KEYS) as SendChoice[]) {
    const { meta, alt } = SEND_KEYS[choice];
    const modifiers = [...(meta ? ["cmd"] : []), ...(alt ? ["opt"] : [])].sort().join("+");
    expect(textInput).toContain(`${modifiers}|\r`);
    expect(sendChoiceForKey({ key: "Enter", metaKey: meta, altKey: alt, shiftKey: false, ctrlKey: false })).toBe(
      choice,
    );
  }
  // Shift-Return adds a line; it is no way to send.
  expect(sendChoiceForKey({ key: "Enter", metaKey: false, altKey: false, shiftKey: true, ctrlKey: false })).toBe(
    undefined,
  );
});
