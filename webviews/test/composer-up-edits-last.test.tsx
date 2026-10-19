// ↑ on an empty agent chat prompt edits the last prompt sent, in its bubble (Codex parity): the
// composer asks the chat (`onEditLast`), and a chat whose last prompt cannot edit keeps ↑'s recall
// of earlier prompts (composer-history.test.ts). A prompt being typed keeps ↑ for its caret.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, summary, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

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
  "getSelection",
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
    getSelection: window.getSelection.bind(window),
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

async function render(
  snapshot: AcpmuxSnapshot,
  blocked?: { reason?: never },
  extra: { onEditLast?: () => boolean } = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        blocked={blocked}
        {...extra}
      />,
    ),
  );
}

const field = () => host.querySelector<HTMLElement>(".acpmux-md")!;
const up = () => {
  const event = new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true, cancelable: true });
  act(() => void field().dispatchEvent(event));
  return event.defaultPrevented;
};

function started(): AcpmuxSnapshot {
  return noChat([], {
    sessionId: "chat",
    summary: { sessionId: "chat", harness: "claude", cwd: "/Users/you/src/app", turnCount: 2 },
    rows: [
      user("Add retries", 1),
      summary(2, { status: "completed" }),
      user("Cover them", 3),
      summary(4, { status: "completed" }),
    ],
  });
}

test("↑ on an empty prompt asks the chat to edit its last prompt", async () => {
  let asked = 0;
  await render(started(), undefined, { onEditLast: () => (asked++, true) });
  expect(up()).toBe(true);
  expect(asked).toBe(1);
});

test("a chat with no prompt to edit leaves ↑ to the recall", async () => {
  let asked = 0;
  await render(started(), undefined, { onEditLast: () => (asked++, false) });
  up();
  expect(asked).toBe(1);
  // The recall brings the last prompt back into the composer instead.
  expect(field().textContent).toBe("Cover them");
});
