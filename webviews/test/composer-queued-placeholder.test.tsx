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
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { SendBlock } from "../src/agent-session/acpmux/useFolderTrustAsk";

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
  // Retained blocked drafts are persisted by Composer on unmount; each test starts a new chat.
  dom.window.localStorage.clear();
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
  blocked?: SendBlock,
  extra: {
    blockSend?: boolean;
    authBlock?: string;
    onOpenInWindow?: () => void;
    handle?: React.Ref<ComposerHandle>;
    onSend?: (text: string, attachments?: unknown, steer?: boolean) => boolean;
    onStop?: () => void;
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

/** Types `text` and clicks the composer's send control; returns each send's steer flag and the
 * send-like controls drawn (Leo 2026-10-31: "THE F***ING TWO SEND BUTTONS"). */
async function click(
  snapshot: AcpmuxSnapshot,
  text = "Use the cache",
  attachments: ComposerAttachment[] = [],
): Promise<{ steers: (boolean | undefined)[]; sends: number; stops: number }> {
  const steers: (boolean | undefined)[] = [];
  let handle: ComposerHandle | null = null;
  await render(snapshot, undefined, {
    handle: (value) => void (handle = value),
    onSend: (_text, _attachments, steer) => {
      steers.push(steer);
      return true;
    },
  });
  await act(async () => handle!.restore(text, attachments));
  const sends = host.querySelectorAll<HTMLButtonElement>(".acpmux-send:not(.acpmux-cancel)");
  const stops = host.querySelectorAll(".acpmux-cancel").length;
  await act(async () => sends[0]?.click());
  return { steers, sends: sends.length, stops };
}

test("mid-turn with a draft, one send control does what Return does: it steers a steering agent", async () => {
  expect(await click(steering({ isWorking: true }))).toEqual({ steers: [true], sends: 1, stops: 0 });
});

test("mid-turn with a draft, the one send control queues for an agent that cannot steer", async () => {
  expect(await click(started({ isWorking: true }))).toEqual({ steers: [false], sends: 1, stops: 0 });
});

test("mid-turn with only an attachment staged, the slot is Send (it steers), never Stop alone", async () => {
  const file: ComposerAttachment = {
    id: "a1",
    kind: "text",
    name: "notes.txt",
    mimeType: "text/plain",
    size: 5,
    text: "notes",
  };
  expect(await click(steering({ isWorking: true }), "", [file])).toEqual({ steers: [true], sends: 1, stops: 0 });
});

test("mid-turn with a draft typed, Esc still stops the turn and keeps the draft", async () => {
  const stops: number[] = [];
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  await render(steering({ isWorking: true }), undefined, {
    handle: (value) => void (handle = value),
    onSend: (text) => {
      sent.push(text);
      return true;
    },
    onStop: () => stops.push(1),
  });
  await act(async () => handle!.restore("Use the cache", []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  // The double press (escapeStop.ts) by default: the first arms, the second stops.
  for (let press = 0; press < 2; press++)
    await act(async () => {
      field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    });
  expect({ stops: stops.length, sent, draft: handle!.draftText().trim() }).toEqual({
    stops: 1,
    sent: [],
    draft: "Use the cache",
  });
});

test("the Quick Composer, whose Esc hides its panel, keeps Stop beside its one Send while a draft is typed", async () => {
  let handle: ComposerHandle | null = null;
  await render(steering({ isWorking: true }), undefined, {
    onOpenInWindow: () => {},
    handle: (value) => void (handle = value),
  });
  await act(async () => handle!.restore("Use the cache", []));
  expect({
    sends: host.querySelectorAll(".acpmux-send:not(.acpmux-cancel)").length,
    stops: host.querySelectorAll(".acpmux-cancel").length,
  }).toEqual({ sends: 1, stops: 1 });
});

test("mid-turn with an empty prompt, the send slot is Stop alone", async () => {
  await render(steering({ isWorking: true }));
  expect({
    sends: host.querySelectorAll(".acpmux-send:not(.acpmux-cancel)").length,
    stops: host.querySelectorAll(".acpmux-cancel").length,
  }).toEqual({ sends: 0, stops: 1 });
});

test("⌘Return queues behind a steering agent's running turn", async () => {
  expect(await press(steering({ isWorking: true }), true)).toEqual([false]);
});

test("an agent that cannot steer queues on both keys; nothing stops the turn", async () => {
  expect(await press(started({ isWorking: true }), false)).toEqual([false]);
  expect(await press(started({ isWorking: true }), true)).toEqual([false]);
  await render(started({ isWorking: true }));
  expect(shown()).toBe("Queue a follow-up");
  expect(host.querySelectorAll(".acpmux-send:not(.acpmux-cancel)").length).toBeLessThanOrEqual(1);
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
  await render(started({ isWorking: true }), { reason: "trust.answerFirst" });
  expect(shown()).toBe("Type / for commands");
});

// A trust read exposes an empty block; the daemon remains the authority and may refuse the
// prompt. Only an actual trust answer or the separate folder-choice flow keeps it in the field.
for (const method of ["click", "return"] as const) {
  test(`an empty trust-read block allows ${method} to send the draft`, async () => {
    const sent: string[] = [];
    let handle: ComposerHandle | null = null;
    await render(
      started(),
      {},
      {
        handle: (value) => void (handle = value),
        onSend: (text) => {
          sent.push(text);
          return true;
        },
      },
    );
    await act(async () => handle!.restore("Use the cache", []));
    const send = host.querySelector<HTMLButtonElement>(".acpmux-send:not(.acpmux-cancel)")!;
    expect(send.disabled).toBe(false);
    await act(async () => {
      if (method === "click") send.click();
      else
        host
          .querySelector<HTMLElement>("[role=combobox]")!
          .dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    });
    expect(sent).toEqual(["Use the cache"]);
  });
}

test("a trust read keeps the running turn's steer and queue choices", async () => {
  await render(steering({ isWorking: true }), {});
  expect(shown()).toBe("↵ steer · ⌘↵ queue");
});

test("a concrete trust block keeps the draft for click and Return", async () => {
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  await render(
    started(),
    { reason: "trust.answerFirst" },
    {
      handle: (value) => void (handle = value),
      onSend: (text) => {
        sent.push(text);
        return true;
      },
    },
  );
  await act(async () => handle!.restore("Keep this draft", []));
  const send = host.querySelector<HTMLButtonElement>(".acpmux-send:not(.acpmux-cancel)")!;
  expect(send.disabled).toBe(true);
  await act(async () => {
    send.click();
    host
      .querySelector<HTMLElement>("[role=combobox]")!
      .dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  expect(sent).toEqual([]);
  expect(host.querySelector("[role=combobox]")!.textContent).toContain("Keep this draft");
});

test("a pending folder choice is a hard stop even for a trust-resend handle", async () => {
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  await render(
    started(),
    {},
    {
      blockSend: true,
      handle: (value) => void (handle = value),
      onSend: (text) => {
        sent.push(text);
        return true;
      },
    },
  );
  await act(async () => handle!.restore("Choose a folder first", []));
  expect(host.querySelector<HTMLButtonElement>(".acpmux-send:not(.acpmux-cancel)")!.disabled).toBe(true);
  let accepted: boolean | undefined;
  await act(async () => {
    accepted = handle!.send();
  });
  expect(accepted).toBe(false);
  expect(sent).toEqual([]);
  expect(host.querySelector("[role=combobox]")!.textContent).toContain("Choose a folder first");
});

test("an auth refusal blocks a trust-read draft and the trust-resend handle", async () => {
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  await render(
    started(),
    {},
    {
      authBlock: "Sign in to send",
      handle: (value) => void (handle = value),
      onSend: (text) => {
        sent.push(text);
        return true;
      },
    },
  );
  await act(async () => handle!.restore("Keep this draft", []));
  const send = host.querySelector<HTMLButtonElement>(".acpmux-send:not(.acpmux-cancel)")!;
  expect(send.disabled).toBe(true);
  let accepted: boolean | undefined;
  await act(async () => {
    send.click();
    host
      .querySelector<HTMLElement>("[role=combobox]")!
      .dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    accepted = handle!.send();
  });
  expect(accepted).toBe(false);
  expect(sent).toEqual([]);
  expect(host.querySelector("[role=combobox]")!.textContent).toContain("Keep this draft");
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
  const field = host.querySelector(".acpmux-composer-prompt");
  expect(form).not.toBeNull();
  expect(field).not.toBeNull();
  for (const [index, working] of [true, false, true, false, true].entries()) {
    await render(steering({ isWorking: working }));
    // Every other switch, the pane changes width too (Session Info opening or closing beside it).
    if (index % 2 === 0) await act(async () => void window.dispatchEvent(new window.Event("resize")));
    expect(host.querySelectorAll(".acpmux-composer")).toHaveLength(1);
    expect(host.querySelectorAll(".acpmux-composer-box")).toHaveLength(1);
    expect(host.querySelectorAll(".acpmux-composer-prompt")).toHaveLength(1);
    expect(host.querySelector(".acpmux-composer")).toBe(form);
    expect(host.querySelector(".acpmux-composer-prompt")).toBe(field);
    expect(host.querySelectorAll(".acpmux-md-placeholder")).toHaveLength(1);
    expect(shown()).toBe(working ? "↵ steer · ⌘↵ queue" : "Type / for commands");
  }
});
