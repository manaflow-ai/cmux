// While a turn runs, a prompt sent from the composer waits behind it (⌘Return steers instead), so
// the empty prompt teaches both keys, as Claude's composer does ("↵ to send, ⌘↵ to queue for
// later"; Leo 2026-10-18): "↵ to queue, ⌘↵ to steer", or "⌘↵ to interrupt" for an agent that
// cannot take a prompt mid-turn. The Quick Composer, whose ⌘Return opens the window, says "Queue a
// follow-up". An idle chat, and a running one whose composer cannot send (blocked), keep the usual
// placeholder.
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

async function render(
  snapshot: AcpmuxSnapshot,
  blocked?: { reason?: never },
  extra: { onOpenInWindow?: () => void } = {},
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

const steering = (fields: Partial<AcpmuxSnapshot> = {}) => {
  const snapshot = started(fields);
  return { ...snapshot, summary: { ...snapshot.summary!, steering: true } };
};

test("a running turn teaches its two keys: Return queues, ⌘Return steers", async () => {
  await render(steering({ isWorking: true }));
  expect(shown()).toBe("↵ to queue, ⌘↵ to steer");
});

test("an agent that cannot steer says ⌘Return interrupts", async () => {
  await render(started({ isWorking: true }));
  expect(shown()).toBe("↵ to queue, ⌘↵ to interrupt");
});

test("the Quick Composer, whose ⌘Return opens the window, only says it queues", async () => {
  await render(steering({ isWorking: true }), undefined, { onOpenInWindow: () => {} });
  expect(shown()).toBe("Queue a follow-up");
});

test("an idle chat keeps the usual placeholder", async () => {
  await render(started({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] }));
  expect(shown()).toBe("Do anything");
  await render(started({ isWorking: true }));
  expect(shown()).toBe("↵ to queue, ⌘↵ to interrupt");
  // The turn ended: back to the idle placeholder.
  await render(started({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] }));
  expect(shown()).toBe("Do anything");
});

test("a running turn whose composer cannot send keeps the usual placeholder", async () => {
  await render(started({ isWorking: true }), {});
  expect(shown()).toBe("Do anything");
});
