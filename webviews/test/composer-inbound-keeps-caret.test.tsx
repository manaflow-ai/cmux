// The composer touches focus and the selection only for what the person does (Leo, 2026-10-20: the
// caret jumped to the start of the prompt mid-sentence when another agent's steer or queued message
// arrived). Inbound messages, queue changes and turn changes re-render the composer with a new
// snapshot; the prompt's text, caret, selection and focus stay exactly as the person left them.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { assistant, noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { promptField } from "../src/agent-session/acpmux/promptFieldTesting";

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

async function render(snapshot: AcpmuxSnapshot, handle?: React.Ref<ComposerHandle>) {
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
        {...(handle ? { handle } : {})}
      />,
    ),
  );
  // The field's own effects and the editor's async setup settle.
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

function chat(fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  return noChat([], {
    sessionId: "chat",
    summary: { sessionId: "chat", harness: "claude", cwd: "/Users/you/src/app", turnCount: 1, steering: true },
    rows: [user("Add retries", 1)],
    isWorking: true,
    ...fields,
  });
}

/// The prompt's selection in the plain text, and whether the editable element still has focus.
function where() {
  const field = promptField(document);
  const { selectionStart, selectionEnd } = field.handle.text();
  return { selectionStart, selectionEnd, focused: document.activeElement === field.element, element: field.element };
}

// Leo 2026-10-20: the caret jumped to the start of the prompt while he typed, when another agent's
// steer or queued message came in. Nothing the person did not do may move focus or the selection:
// not an inbound message, a queue change, a turn starting or ending, or any snapshot update.
test("an inbound agent message while typing mid-text leaves the caret, selection and focus alone", async () => {
  await render(chat());
  const field = promptField(document);
  await act(async () => {
    field.handle.focus();
    field.handle.type("fix the flaky retry test");
  });
  // The person puts the caret mid-text and selects a word ("flaky").
  await act(async () => field.handle.writeText("fix the flaky retry test", 8, 13));
  const before = where();
  expect(before).toMatchObject({ selectionStart: 8, selectionEnd: 13, focused: true });

  const steps: Partial<AcpmuxSnapshot>[] = [
    // Another agent's message waits in the queue.
    { queue: [{ id: "agent-1", prompt: "From a162: rebase first" }] },
    // It is sent now (a steer) and lands in the transcript.
    { queue: [{ id: "agent-1", prompt: "From a162: rebase first", next: true }] },
    {
      queue: [],
      rows: [user("Add retries", 1), user("From a162: rebase first", 2, { steer: "waiting" })],
    },
    // The agent answers and the turn ends.
    {
      queue: [],
      rows: [user("Add retries", 1), user("From a162: rebase first", 2), assistant("Rebased.", 3)],
      isWorking: false,
    },
  ];
  for (const step of steps) {
    await render(chat(step));
    const now = where();
    expect(now.element).toBe(before.element);
    expect({ ...now, element: undefined }).toEqual({ ...before, element: undefined });
    expect(promptField(document).value).toBe("fix the flaky retry test");
  }
});

test("an inbound agent message never takes focus the person put elsewhere", async () => {
  await render(chat());
  const field = promptField(document);
  await act(async () => field.handle.type("draft in progress"));
  const elsewhere = document.createElement("button");
  document.body.append(elsewhere);
  elsewhere.focus();
  await render(chat({ queue: [{ id: "agent-2", prompt: "From b7: tests pass" }] }));
  await render(chat({ queue: [], rows: [user("Add retries", 1), user("From b7: tests pass", 2)] }));
  expect(document.activeElement).toBe(elsewhere);
  elsewhere.remove();
});
