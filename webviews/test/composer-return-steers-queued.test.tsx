// Return on an empty prompt while a turn runs steers the next queued prompt into it, as the Claude
// app does (https://github.com/manaflow-ai/cmux/issues/34765): the queued row's Steer, from the
// keyboard (`_acpmux/queue_edit` send_now). One press steers one prompt, the next press the one
// after it; a held key's repeats steer none. A teammate's prompt, one already steering, a typed
// prompt (Return sends that instead) and an idle chat are left alone.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { SendBlock } from "../src/agent-session/acpmux/useFolderTrustAsk";
import type { QueueEdit } from "../src/agent-session/acpmux/model";

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
    authChecking?: boolean;
    onOpenInWindow?: () => void;
    handle?: React.Ref<ComposerHandle>;
    onSend?: (text: string, attachments?: unknown, steer?: boolean) => boolean;
    onQueueChange?: (promptId: string, edit: QueueEdit) => Promise<boolean>;
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

const queue = (...entries: AcpmuxSnapshot["queue"]) => entries;

/** Renders `snapshot`, presses Return `presses` times (with `repeat` after the first when held),
 * and returns the queue edits and sends the composer made. */
async function returnOn(
  snapshot: AcpmuxSnapshot,
  {
    presses = 1,
    held = false,
    typed = "",
    answer = true,
  }: { presses?: number; held?: boolean; typed?: string; answer?: boolean } = {},
) {
  const edits: [string, QueueEdit][] = [];
  const sends: string[] = [];
  let handle: ComposerHandle | null = null;
  await render(snapshot, undefined, {
    handle: (value) => void (handle = value),
    onSend: (text) => {
      sends.push(text);
      return true;
    },
    onQueueChange: async (promptId, edit) => {
      edits.push([promptId, edit]);
      return answer;
    },
  });
  if (typed) await act(async () => handle!.restore(typed, []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  for (let press = 0; press < presses; press++) {
    await act(async () => {
      field.dispatchEvent(
        new window.KeyboardEvent("keydown", {
          key: "Enter",
          repeat: held && press > 0,
          bubbles: true,
          cancelable: true,
        }),
      );
    });
  }
  return { edits, sends };
}

test("Return on an empty prompt steers the first queued prompt into the running turn", async () => {
  const { edits, sends } = await returnOn(
    steering({
      isWorking: true,
      queue: queue({ id: "p-1", prompt: "Use the cache" }, { id: "p-2", prompt: "Then rerun" }),
    }),
  );
  expect(edits).toEqual([["p-1", { op: "send_now" }]]);
  expect(sends).toEqual([]);
});

test("each Return steers the next queued prompt; a held key's repeats steer none", async () => {
  const snapshot = steering({
    isWorking: true,
    queue: queue({ id: "p-1", prompt: "Use the cache" }, { id: "p-2", prompt: "Then rerun" }),
  });
  expect((await returnOn(snapshot, { presses: 2 })).edits.map(([id]) => id)).toEqual(["p-1", "p-2"]);
  act(() => root?.unmount());
  root = undefined;
  expect((await returnOn(snapshot, { presses: 3, held: true })).edits.map(([id]) => id)).toEqual(["p-1"]);
});

test("a refused steer lets the next Return try the same prompt again", async () => {
  const { edits } = await returnOn(
    steering({ isWorking: true, queue: queue({ id: "p-1", prompt: "Use the cache" }) }),
    {
      presses: 2,
      answer: false,
    },
  );
  expect(edits.map(([id]) => id)).toEqual(["p-1", "p-1"]);
});

test("a teammate's prompt, one already steering, a trust-held one and one still sending are not steered by Return", async () => {
  const { edits } = await returnOn(
    steering({
      isWorking: true,
      queue: queue(
        { id: "p-next", prompt: "Already sent now", next: true },
        { id: "p-theirs", prompt: "Ana's", author: { id: "ana", name: "Ana" } },
        { id: "p-held", prompt: "Held for trust", held: true },
        { id: "p-sending", prompt: "Not queued by acpmux yet", sending: true },
        { id: "p-mine", prompt: "Mine" },
      ),
    }),
  );
  expect(edits).toEqual([["p-mine", { op: "send_now" }]]);
});

test("a typed prompt still goes on Return, and an idle chat's Return steers nothing", async () => {
  const typed = await returnOn(steering({ isWorking: true, queue: queue({ id: "p-1", prompt: "Use the cache" }) }), {
    typed: "A new thought",
  });
  expect(typed.edits).toEqual([]);
  expect(typed.sends).toEqual(["A new thought"]);
  act(() => root?.unmount());
  root = undefined;
  const idle = await returnOn(steering({ isWorking: false, queue: queue({ id: "p-1", prompt: "Use the cache" }) }));
  expect(idle.edits).toEqual([]);
});
