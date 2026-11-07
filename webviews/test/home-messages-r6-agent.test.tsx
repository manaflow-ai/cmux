// Review round 6 of cmux#37736 (package "agent"): the native transcript's Chief surfaces on the
// React Messages page. Stop, Escape, Cmd-., Option-click Stop all agents with its toast and Restart,
// and Continue after a stop (ChatController+Stop.swift, HomeChiefTurnActions, HomeHostView+StopAll);
// the toast's room under the newest message (+ToastRoom.swift); rows added beside the messages.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { MessageComposer } = await import("../src/pages/home-messages/transcript/MessageComposer");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { ChiefTurn, CHIEF_TURN_OPS, stopAllMessage } = await import("../src/pages/home-messages/transcript/chiefTurn");
const { withExtras } = await import("../src/pages/home-messages/transcript/extras");
type PageClient = import("../src/pages/shared/pageClient").PageClient;
type TranscriptRow = import("../src/pages/home-messages/transcript/rows").TranscriptRow;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

/** A host that answers each op from `answers` and records the calls. */
function fakeHost(answers: Record<string, unknown | Error>) {
  const calls: { op: string; params: Record<string, unknown> }[] = [];
  const host: PageClient = {
    call: async <T,>(op: string, params: Record<string, unknown> = {}) => {
      calls.push({ op, params });
      const answer = answers[op];
      if (answer instanceof Error) throw answer;
      return answer as T;
    },
    subscribe: () => Promise.reject(new Error("none")),
    handle: () => () => {},
  } as unknown as PageClient;
  return { host, calls };
}

test("Stop goes to the conversation's Chief, and Continue follows a stop the brain accepted", async () => {
  const { host, calls } = fakeHost({
    [CHIEF_TURN_OPS.stop]: { stopped: true },
    [CHIEF_TURN_OPS.continue]: { continued: true },
  });
  const turn = new ChiefTurn(host, "c1", strings);
  turn.update(true, 4);
  expect(turn.getSnapshot()).toEqual({ working: true, continueAvailable: false });
  turn.stop();
  await settle();
  expect(calls).toEqual([{ op: CHIEF_TURN_OPS.stop, params: { conversation: "c1" } }]);
  // Still working until the next idle snapshot: no Continue yet.
  expect(turn.getSnapshot().continueAvailable).toBe(false);
  turn.update(false, 4);
  expect(turn.getSnapshot().continueAvailable).toBe(true);
  turn.continueTurn();
  await settle();
  expect(calls.at(-1)?.op).toBe(CHIEF_TURN_OPS.continue);
  expect(turn.getSnapshot().continueAvailable).toBe(false);
  turn.dispose();
});

test("a new message or a new turn ends a stop's Continue", async () => {
  const { host } = fakeHost({ [CHIEF_TURN_OPS.stop]: { stopped: true } });
  const turn = new ChiefTurn(host, "c1", strings);
  turn.update(true, 4);
  turn.stop();
  await settle();
  turn.update(false, 4);
  expect(turn.getSnapshot().continueAvailable).toBe(true);
  turn.update(false, 5);
  expect(turn.getSnapshot().continueAvailable).toBe(false);
  turn.dispose();
});

test("Stop all agents shows what stopped, and Restart starts those subagents again", async () => {
  const { host, calls } = fakeHost({
    [CHIEF_TURN_OPS.stopAll]: {
      stopped: true,
      subagents: ["a1", "a2"],
      errors: ["a3: busy"],
      note: "a4 is still starting",
    },
    [CHIEF_TURN_OPS.restart]: { restarted: true },
  });
  const turn = new ChiefTurn(host, "c1", strings);
  turn.update(true, 1);
  turn.stop(true);
  await settle();
  const toast = turn.getSnapshot().toast!;
  expect(toast.message.split("\n")).toEqual([
    "Stopped all agents: a1 and a2",
    "1 could not be stopped",
    "a4 is still starting",
  ]);
  expect(toast.detail).toBe("a3: busy\na4 is still starting");
  expect(toast.restart).toEqual(["a1", "a2"]);
  turn.restart(toast.restart!);
  await settle();
  expect(calls.at(-1)).toEqual({ op: CHIEF_TURN_OPS.restart, params: { conversation: "c1", names: ["a1", "a2"] } });
  expect(turn.getSnapshot().toast).toBeUndefined();
  turn.dispose();
});

test("the stop-all lines when no subagent ran", () => {
  expect(stopAllMessage({ stopped: true, subagents: [], errors: [] }, strings)).toBe(
    "Stopped the Chief; no subagents were running",
  );
  expect(stopAllMessage({ stopped: false, subagents: [], errors: [] }, strings)).toBe("No agents were running");
});

test("a refused stop says why in a toast", async () => {
  const { host } = fakeHost({ [CHIEF_TURN_OPS.stop]: Object.assign(new Error("The Chief could not be reached")) });
  const turn = new ChiefTurn(host, "c1", strings);
  turn.update(true, 1);
  turn.stop();
  await settle();
  expect(turn.getSnapshot().toast?.message).toBe("The Chief could not be reached");
  turn.dispose();
});

async function renderComposer(container: HTMLElement, props: Partial<Parameters<typeof MessageComposer>[0]>) {
  await act(async () => {
    root = createRoot(container);
    root.render(<MessageComposer strings={strings} sendEnabled onSend={async () => true} {...props} />);
  });
  await settle();
}

test("while the Chief works the emoji button is Stop; Option-click stops all agents", async () => {
  const container = installDom();
  const stops: boolean[] = [];
  await renderComposer(container, {
    chief: { working: true, continueAvailable: false, onStop: (all) => stops.push(all), onContinue: () => {} },
  });
  const stop = container.querySelector<HTMLButtonElement>(`button[aria-label="${strings.t("compose.stop")}"]`)!;
  expect(stop).not.toBeNull();
  expect(container.querySelector(`button[aria-label="${strings.t("compose.emoji")}"]`)).toBeNull();
  expect(stop.title).toBe("Stop the Chief (Option-click: Stop All Agents)");
  await act(async () => stop.click());
  await act(async () => stop.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, altKey: true })));
  expect(stops).toEqual([false, true]);
});

test("Escape and Cmd-. in the message box stop a working Chief", async () => {
  const container = installDom();
  const stops: boolean[] = [];
  await renderComposer(container, {
    chief: { working: true, continueAvailable: false, onStop: (all) => stops.push(all), onContinue: () => {} },
  });
  const field = container.querySelector<HTMLElement>(".ProseMirror")!;
  expect(field).not.toBeNull();
  await act(async () => {
    field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    field.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: ".", metaKey: true, bubbles: true, cancelable: true }),
    );
  });
  expect(stops).toEqual([false, false]);
});

test("after a stop the button is Continue; idle it is the emoji button again", async () => {
  const container = installDom();
  let continued = 0;
  await renderComposer(container, {
    chief: { working: false, continueAvailable: true, onStop: () => {}, onContinue: () => (continued += 1) },
  });
  const button = container.querySelector<HTMLButtonElement>(
    `button[aria-label="${strings.t("home.compose.continue")}"]`,
  )!;
  expect(button).not.toBeNull();
  await act(async () => button.click());
  expect(continued).toBe(1);
  act(() =>
    root!.render(
      <MessageComposer
        strings={strings}
        sendEnabled
        onSend={async () => true}
        chief={{ working: false, continueAvailable: false, onStop: () => {}, onContinue: () => {} }}
      />,
    ),
  );
  expect(container.querySelector(`button[aria-label="${strings.t("compose.emoji")}"]`)).not.toBeNull();
});

const bubble = (id: string): TranscriptRow =>
  ({ kind: "bubble", key: `part:${id}:0`, gap: 0, message: { id } }) as unknown as TranscriptRow;
const receipt = (id: string): TranscriptRow =>
  ({ kind: "receipt", key: `receipt:${id}`, gap: 0, receipt: "read" }) as unknown as TranscriptRow;

test("added rows go after their message's own rows and at the end", () => {
  const rows = [bubble("m1"), bubble("m1"), receipt("m1"), bubble("m2")];
  const shown = withExtras(rows, {
    after: new Map([["m1", [{ key: "agents:m1", estimate: 30, node: null }]]]),
    tail: [{ key: "status", estimate: 20, node: null }],
  });
  expect(shown.map((row) => row.key)).toEqual([
    "part:m1:0",
    "part:m1:0",
    "receipt:m1",
    "agents:m1",
    "part:m2:0",
    "status",
  ]);
  expect(withExtras(rows, undefined)).toBe(rows);
});

const { MessagesTranscript } = await import("../src/pages/home-messages/transcript/MessagesTranscript");
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;
type HomeMessage = import("../src/pages/home-channels/types").HomeMessage;

const chiefChat: HomeConversation = {
  id: "c1",
  owner: "local",
  title: "Chief",
  kind: "chief",
  participants: [
    { id: "me", kind: "human", name: "Me", chief: false },
    { id: "chief", kind: "agent", name: "Chief", chief: true },
  ],
  lastSeq: 2,
  rev: 1,
  updatedAt: 0,
  unread: 0,
  mentions: 0,
  muted: false,
  pinned: false,
};
const twoMessages: HomeMessage[] = ["me", "chief"].map((author, index) => ({
  id: `m${index}`,
  conversation: "c1",
  seq: index + 1,
  author,
  createdAt: 1_700_000_000_000 + index * 1000,
  retracted: false,
  parts: [{ type: "text", text: `message ${index}`, mentions: [] }],
  reactions: [],
}));

test("a toast over the message box takes room under the newest message, and gives it back", async () => {
  const container = installDom();
  // The toast measures 40 px; the observer reports at once.
  Object.defineProperty(dom!.window.HTMLElement.prototype, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("mt-toast-room") ? 40 : 0;
    },
  });
  scope.ResizeObserver = class {
    constructor(private readonly run: (entries: unknown[]) => void) {}
    observe() {
      this.run([]);
    }
    unobserve() {}
    disconnect() {}
  };
  const render = (toast?: string) =>
    root!.render(
      <MessagesTranscript
        strings={strings}
        me="me"
        conversation={chiefChat}
        messages={twoMessages}
        connection="online"
        onSend={async () => true}
        onLoadOlder={() => {}}
        now={1_700_000_010_000}
        {...(toast ? { toast: <span>{toast}</span> } : {})}
      />,
    );
  await act(async () => {
    root = createRoot(container);
    render("Stopped all agents: a1");
  });
  await settle();
  expect(container.querySelector(".mt-compose .mt-toast-room")?.textContent).toBe("Stopped all agents: a1");
  const keys = () => [...container.querySelectorAll<HTMLElement>(".mt-slot")].map((slot) => slot.dataset.key);
  expect(keys().at(-1)).toBe("toast-room");
  await act(async () => render());
  await settle();
  expect(keys()).not.toContain("toast-room");
});
