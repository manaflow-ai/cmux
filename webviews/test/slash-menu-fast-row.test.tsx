// The `/` menu's Fast row reads like ChatGPT's (Leo 2026-10-22, relayed by claude-sr2: "Match
// theirs: icon, plain name, a sentence saying what selecting it does in the current state."): the
// bolt, the plain name "Fast" rather than "/fast", and what picking it does now, from the chat's
// fast mode option, in place of Claude Code's own "Toggle fast mode (Opus 5.5)". Typing `/fast`
// still finds the row, picking it still writes `/fast `, and Return sends it as before. Other rows
// keep their `/name` and the agent's description.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";

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
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
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

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

let chats = 0;

/// A Claude chat that lists `/fast` as Claude Code does, with its fast mode option at `fast`
/// (none: the session reports no such option).
function chat(fast?: "on" | "off"): AcpmuxSnapshot {
  const sessionId = `fast-row-${++chats}`;
  return noChat([], {
    sessionId,
    summary: {
      sessionId,
      harness: "claude",
      cwd: "/Users/you/src/app",
      turnCount: 1,
      ...(fast
        ? {
            configOptions: [
              {
                id: "fast-mode",
                name: "Fast mode",
                category: "model_config",
                currentValue: fast,
                options: [
                  { value: "off", name: "Off" },
                  { value: "on", name: "On" },
                ],
              },
            ],
          }
        : {}),
    },
    rows: [user("Add retries", 1)],
    commands: [
      { name: "fast", description: "Toggle fast mode (Opus 5.5)", source: "agent" },
      { name: "review", description: "Review a pull request", source: "agent" },
    ],
  });
}

async function composer(snapshot: AcpmuxSnapshot, typed: string) {
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={(text) => {
          sent.push(text);
          return true;
        }}
        onStop={() => {}}
        localName="studio"
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  return { field, sent };
}

const rows = () => [...host.querySelectorAll<HTMLElement>("#acpmux-slash-menu [role='option']")];
const text = (row: HTMLElement | undefined, selector: string) =>
  row?.querySelector(selector)?.textContent?.trim() ?? null;
/// The `/fast` command's row, by the name it shows (base: "/fast"; ChatGPT's look: "Fast").
const fastRow = () => rows().find((row) => /^\/?fast$/i.test(text(row, ".acpmux-slash-name") ?? ""));

async function press(field: HTMLElement, key: string) {
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key, keyCode: 13, bubbles: true, cancelable: true }));
  });
}

test("with Fast on, the row is the bolt, Fast, and turning it off", async () => {
  await composer(chat("on"), "/fast");
  const row = fastRow();
  expect(text(row, ".acpmux-slash-name")).toBe("Fast");
  expect(row!.querySelector(".acpmux-slash-icon svg")).not.toBeNull();
  expect(text(row, ".acpmux-slash-description")).toBe("Turn off Fast and return to standard speed");
});

test("with Fast off, the row says picking it turns Fast on", async () => {
  await composer(chat("off"), "/fast");
  const row = fastRow();
  expect(text(row, ".acpmux-slash-name")).toBe("Fast");
  expect(row!.querySelector(".acpmux-slash-icon svg")).not.toBeNull();
  expect(text(row, ".acpmux-slash-description")).toBe("Turn on Fast for quicker replies");
});

test("a chat that reports no fast mode option still names the row plainly", async () => {
  await composer(chat(), "/fast");
  const row = fastRow();
  expect(text(row, ".acpmux-slash-name")).toBe("Fast");
  expect(text(row, ".acpmux-slash-description")).toBe("Turn Fast on or off");
});

test("other rows keep their /name and the agent's description, and no icon", async () => {
  await composer(chat("on"), "/");
  const review = rows().find((row) => text(row, ".acpmux-slash-name") === "/review");
  expect(review).toBeDefined();
  expect(text(review, ".acpmux-slash-description")).toBe("Review a pull request");
  expect(review!.querySelector(".acpmux-slash-icon")).toBeNull();
  // The Fast row is in the full list too.
  expect(text(fastRow(), ".acpmux-slash-name")).toBe("Fast");
});

test("typing /fast finds the row; Return picks it and Return again sends /fast", async () => {
  const { field, sent } = await composer(chat("off"), "/fa");
  expect(text(rows()[0], ".acpmux-slash-name")).toBe("Fast");
  await press(field, "Enter");
  expect(host.querySelector("#acpmux-slash-menu")).toBeNull();
  expect(field.textContent?.trim()).toBe("/fast");
  await press(field, "Enter");
  expect(sent).toEqual(["/fast"]);
});
