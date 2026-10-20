// While a turn runs, Return reaches the agent at once, as the Chief's tell does (user 2026-10-20:
// never wait for the turn): it steers an agent that takes a prompt mid-turn, else stops the turn
// and runs next; ⌘Return stops the turn now; ⌥Return queues. The empty prompt teaches the keys:
// "↵ to steer, ⌘↵ to interrupt, ⌥↵ to queue", or "↵ to interrupt, ⌥↵ to queue" for an agent that
// cannot steer or with only attachments staged (a steer needs typed text). The Quick Composer,
// whose ⌘Return opens the window, names Return only: "↵ to steer" or "↵ to interrupt". An idle chat, and a running one whose composer cannot send
// (blocked), keep the usual placeholder. Which flag each key sends: agent-pane-steer.test.ts.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, summary, user } from "../src/gallery/fixtures/acpmux";
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
  extra: { onOpenInWindow?: () => void; handle?: React.Ref<ComposerHandle> } = {},
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

test("an agent that steers: Return steers, ⌘Return interrupts, ⌥Return queues", async () => {
  await render(steering({ isWorking: true }));
  expect(shown()).toBe("↵ to steer, ⌘↵ to interrupt, ⌥↵ to queue");
});

test("an agent that cannot steer: Return interrupts, ⌥Return queues", async () => {
  await render(started({ isWorking: true }));
  expect(shown()).toBe("↵ to interrupt, ⌥↵ to queue");
});

test("the Quick Composer, whose ⌘Return opens the window, only names Return", async () => {
  await render(steering({ isWorking: true }), undefined, { onOpenInWindow: () => {} });
  expect(shown()).toBe("↵ to steer");
  await render(started({ isWorking: true }), undefined, { onOpenInWindow: () => {} });
  expect(shown()).toBe("↵ to interrupt");
});

test("with only an attachment staged, ⌘Return has nothing to steer, so it names Return and ⌥Return", async () => {
  let handle: ComposerHandle | null = null;
  await render(steering({ isWorking: true }), undefined, { handle: (value) => void (handle = value) });
  await act(async () =>
    handle!.restore("", [{ id: "a", kind: "text", name: "notes.txt", mimeType: "text/plain", size: 5, text: "notes" }]),
  );
  expect(shown()).toBe("↵ to interrupt, ⌥↵ to queue");
});

test("an idle chat keeps the usual placeholder", async () => {
  await render(started({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] }));
  expect(shown()).toBe("Do anything");
  await render(started({ isWorking: true }));
  expect(shown()).toBe("↵ to interrupt, ⌥↵ to queue");
  // The turn ended: back to the idle placeholder.
  await render(started({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] }));
  expect(shown()).toBe("Do anything");
});

test("a running turn whose composer cannot send keeps the usual placeholder", async () => {
  await render(started({ isWorking: true }), {});
  expect(shown()).toBe("Do anything");
});
