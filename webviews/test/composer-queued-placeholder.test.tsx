// While a turn runs, the empty prompt teaches both keys, as Claude's composer does. An agent that
// steers takes Return into the running turn (it reads the prompt when its current step ends) and
// ⌘Return queues it for after the turn: "↵ steer · ⌘↵ queue" (Leo 2026-10-20). The Quick Composer,
// whose ⌘Return opens the window, says "Steer this turn…". Nothing sent stops the turn: an agent
// that cannot take a prompt mid-turn queues on both keys and says "Queue a follow-up". An idle
// chat, and a running one whose composer cannot send (blocked), keep the usual placeholder.
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

async function render(
  snapshot: AcpmuxSnapshot,
  blocked?: { reason?: never },
  extra: {
    onOpenInWindow?: () => void;
    handle?: React.Ref<ComposerHandle>;
    onSend?: (text: string, attachments?: unknown, steer?: boolean) => boolean;
  } = {},
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

test("a running turn teaches its two keys: Return steers, ⌘Return queues", async () => {
  await render(steering({ isWorking: true }));
  expect(shown()).toBe("↵ steer · ⌘↵ queue");
});

/** Types `text` and presses Return (⌘Return with `command`); returns each send's steer flag. */
async function press(snapshot: AcpmuxSnapshot, command: boolean): Promise<(boolean | undefined)[]> {
  const steers: (boolean | undefined)[] = [];
  let handle: ComposerHandle | null = null;
  await render(snapshot, undefined, {
    handle: (value) => void (handle = value),
    onSend: (_text, _attachments, steer) => {
      steers.push(steer);
      return true;
    },
  });
  await act(async () => handle!.restore("Use the cache", []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  await act(async () => {
    field.dispatchEvent(
      new window.KeyboardEvent("keydown", {
        key: "Enter",
        metaKey: command,
        bubbles: true,
        cancelable: true,
      }),
    );
  });
  return steers;
}

test("Return steers a steering agent's running turn", async () => {
  expect(await press(steering({ isWorking: true }), false)).toEqual([true]);
});

test("⌘Return queues behind a steering agent's running turn", async () => {
  expect(await press(steering({ isWorking: true }), true)).toEqual([false]);
});

test("an agent that cannot steer queues on both keys; nothing stops the turn", async () => {
  expect(await press(started({ isWorking: true }), false)).toEqual([false]);
  expect(await press(started({ isWorking: true }), true)).toEqual([false]);
  await render(started({ isWorking: true }));
  expect(shown()).toBe("Queue a follow-up");
  expect(host.querySelector(".acpmux-steer-now")).toBeNull();
});

test("the Quick Composer, whose ⌘Return opens the window, names Return alone", async () => {
  await render(steering({ isWorking: true }), undefined, { onOpenInWindow: () => {} });
  expect(shown()).toBe("Steer this turn…");
  await render(started({ isWorking: true }), undefined, { onOpenInWindow: () => {} });
  expect(shown()).toBe("Queue a follow-up");
});

test("with only an attachment staged, Return steers it and ⌘Return queues it", async () => {
  let handle: ComposerHandle | null = null;
  const steers: (boolean | undefined)[] = [];
  await render(steering({ isWorking: true }), undefined, {
    handle: (value) => void (handle = value),
    onSend: (_text, _attachments, steer) => {
      steers.push(steer);
      return true;
    },
  });
  const note = {
    id: "a",
    kind: "text" as const,
    name: "notes.txt",
    mimeType: "text/plain",
    size: 5,
    text: "notes",
  };
  await act(async () => handle!.restore("", [note]));
  expect(shown()).toBe("↵ steer · ⌘↵ queue");
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  for (const metaKey of [false, true]) {
    await act(async () => handle!.restore("", [note]));
    await act(async () => {
      field.dispatchEvent(
        new window.KeyboardEvent("keydown", {
          key: "Enter",
          metaKey,
          bubbles: true,
          cancelable: true,
        }),
      );
    });
  }
  expect(steers).toEqual([true, false]);
});

test("an idle chat keeps the usual placeholder", async () => {
  await render(started({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] }));
  expect(shown()).toBe("Type / for commands");
  await render(steering({ isWorking: true }));
  expect(shown()).toBe("↵ steer · ⌘↵ queue");
  // The turn ended: back to the idle placeholder.
  await render(started({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] }));
  expect(shown()).toBe("Type / for commands");
});

test("a running turn whose composer cannot send keeps the usual placeholder", async () => {
  await render(started({ isWorking: true }), {});
  expect(shown()).toBe("Type / for commands");
});

// Leo's nightly (d5829ff): a dictated prompt, the agent working with three prompts queued, and
// Return added a line instead of sending. macOS Dictation (like an IME) ends its text with the
// Return key as keyCode 229, which every key handler leaves to the input method, and WebKit then
// inserts the paragraph. Return never adds a line in the composer (Shift-Return does): the
// paragraph input sends instead.
test("a Return the input method passed on as a new paragraph sends, never adds a line", async () => {
  const sent: { text: string; steer?: boolean }[] = [];
  let handle: ComposerHandle | null = null;
  await render(
    steering({
      isWorking: true,
      queue: [
        { id: "q1", prompt: "one" },
        { id: "q2", prompt: "two" },
        { id: "q3", prompt: "three" },
      ],
    }),
    undefined,
    {
      handle: (value) => void (handle = value),
      onSend: (text, _attachments, steer) => {
        sent.push({ text, steer });
        return true;
      },
    },
  );
  await act(async () => handle!.restore("What is Spotlight?", []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  let inserted = true;
  await act(async () => {
    field.dispatchEvent(
      new window.KeyboardEvent("keydown", {
        key: "Enter",
        keyCode: 229,
        bubbles: true,
        cancelable: true,
      }),
    );
    const paragraph = new window.InputEvent("beforeinput", {
      inputType: "insertParagraph",
      bubbles: true,
      cancelable: true,
    });
    inserted = field.dispatchEvent(paragraph);
  });
  expect({ sent, inserted }).toEqual({
    sent: [{ text: "What is Spotlight?", steer: true }],
    inserted: false,
  });
});

// Leo, 2026-10-29: "the fucking rendering is stupid as hell": a running composer ("↵ steer · ⌘↵
// queue") drawn with an idle one ("Type / for commands") over it, at another width. The page draws
// exactly one composer: the same form and field through running↔idle and a pane resize, never a
// kept copy beside it.
test("one composer element, the same one, through running↔idle switches and a pane resize", async () => {
  await render(steering());
  const form = host.querySelector(".acpmux-composer");
  const field = host.querySelector("[role=combobox]");
  expect(form).not.toBeNull();
  for (const [index, working] of [true, false, true, false, true].entries()) {
    await render(steering({ isWorking: working }));
    // Every other switch, the pane changes width too (Session Info opening or closing beside it).
    if (index % 2 === 0) await act(async () => void window.dispatchEvent(new window.Event("resize")));
    expect(host.querySelectorAll(".acpmux-composer")).toHaveLength(1);
    expect(host.querySelectorAll("[role=combobox]")).toHaveLength(1);
    expect(host.querySelector(".acpmux-composer")).toBe(form);
    expect(host.querySelector("[role=combobox]")).toBe(field);
    expect(host.querySelectorAll(".acpmux-md-placeholder")).toHaveLength(1);
    expect(shown()).toBe(working ? "↵ steer · ⌘↵ queue" : "Type / for commands");
  }
});
