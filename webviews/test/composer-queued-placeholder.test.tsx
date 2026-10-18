// While a turn runs, a prompt sent from the composer waits behind it (⌘Return steers instead), so
// the empty prompt says "Queue a follow-up" rather than the idle "Do anything". Idle chats, a new
// chat and the shell prompt keep their own placeholders.
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

async function render(snapshot: AcpmuxSnapshot) {
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
      />,
    ),
  );
}

const shown = () => host.querySelector(".acpmux-md-placeholder")?.textContent;

function started(fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  const snapshot = noChat([], {
    sessionId: "chat",
    summary: { sessionId: "chat", harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
    ...fields,
  });
  return snapshot;
}

test("a running turn turns the empty prompt into a queue prompt", async () => {
  await render(started({ isWorking: true }));
  expect(shown()).toBe("Queue a follow-up");
});

test("an idle chat keeps the usual placeholder", async () => {
  await render(started({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] }));
  expect(shown()).toBe("Do anything");
  await render(started({ isWorking: true }));
  expect(shown()).toBe("Queue a follow-up");
  // The turn ended: back to the idle placeholder.
  await render(started({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] }));
  expect(shown()).toBe("Do anything");
});
