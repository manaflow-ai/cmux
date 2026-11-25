// Settings > Agent Chat > Follow-Up Messages (agentPane.followUpMode, followUpMode.ts): what Return
// does with a message sent while an agent that steers is mid-turn. "steer" (the default) steers it
// into the running turn and ⌘Return queues it; "queue" swaps them: Return and Send queue it for after
// the turn and ⌘Return steers. The composer's onSend carries the choice as its steer flag, which
// acpmux follows (a steer goes into the turn, anything else waits in the queue).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { setComposerSettings } from "../src/agent-session/acpmux/composerSettings";
import { followUpSteers, readFollowUpMode, returnQueues } from "../src/agent-session/acpmux/followUpMode";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { teardownDom } from "./support/domTeardown";

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
  "createImageBitmap",
  "OffscreenCanvas",
  "cmuxExperiments",
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
    createImageBitmap: async (source: Blob) => {
      await source.arrayBuffer();
      return { width: 640, height: 480, close() {} };
    },
    OffscreenCanvas: class {
      constructor(
        public width: number,
        public height: number,
      ) {}
      getContext() {
        return { drawImage() {}, fillRect() {}, fillStyle: "" };
      }
      async convertToBlob({ type }: { type: string }) {
        return new Blob([PNG], { type });
      }
    },
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  delete scope.cmuxExperiments;
  setComposerSettings({ followUpMode: "steer" });
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

type Sent = { text: string; steer?: boolean };

const PNG = new Uint8Array(8);

/** Renders the composer over `snapshot` with `typed` in it; returns its field and what it sent. */
async function composer(snapshot: AcpmuxSnapshot, typed: string) {
  const sent: Sent[] = [];
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
        onSend={(text, _attachments, steer) => {
          sent.push({ text, steer });
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  return { field, sent };
}

let chats = 0;

/** A chat whose agent steers, mid-turn when `working`. */
function chat(working: boolean, steering = true): AcpmuxSnapshot {
  const sessionId = `follow-up-${++chats}`;
  const snapshot = noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1, steering },
    rows: [user("Add retries", 1)],
    isWorking: working,
  });
  return snapshot;
}

async function press(field: HTMLElement, init: KeyboardEventInit) {
  await act(async () => {
    field.dispatchEvent(
      new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Enter", ...init }),
    );
  });
}

const facts = { returnSteers: true, steersAlways: false, steersUnseen: false };

test("the host's value reads as steer unless it says queue", () => {
  expect(readFollowUpMode(undefined)).toBe("steer");
  expect(readFollowUpMode("Queue")).toBe("steer");
  expect(readFollowUpMode("queue")).toBe("queue");
});

test("steer keeps today's keys; queue swaps them; queueing off and a non-steering agent win either way", () => {
  expect(followUpSteers("return", "steer", facts)).toBe(true);
  expect(followUpSteers("commandReturn", "steer", facts)).toBe(false);
  expect(followUpSteers("return", "queue", facts)).toBe(false);
  expect(followUpSteers("commandReturn", "queue", facts)).toBe(true);
  const off = { ...facts, steersAlways: true };
  expect([followUpSteers("return", "queue", off), followUpSteers("commandReturn", "queue", off)]).toEqual([true, true]);
  const cannot = { returnSteers: false, steersAlways: false, steersUnseen: false };
  expect(returnQueues("queue", cannot)).toBe(false);
  expect([followUpSteers("return", "queue", cannot), followUpSteers("commandReturn", "queue", cannot)]).toEqual([
    false,
    false,
  ]);
});

test("by default Return mid-turn steers and Command-Return queues", async () => {
  const { field, sent } = await composer(chat(true), "Also cover the timeout");
  await press(field, {});
  const next = await composer(chat(true), "And the retry count");
  await press(next.field, { metaKey: true });
  expect([...sent, ...next.sent]).toEqual([
    { text: "Also cover the timeout", steer: true },
    { text: "And the retry count", steer: false },
  ]);
});

test("Follow-Up Messages set to Queue: Return mid-turn queues and Command-Return steers", async () => {
  setComposerSettings({ followUpMode: "queue" });
  const { field, sent } = await composer(chat(true), "Also cover the timeout");
  await press(field, {});
  const next = await composer(chat(true), "And the retry count");
  await press(next.field, { metaKey: true });
  expect([...sent, ...next.sent]).toEqual([
    { text: "Also cover the timeout", steer: false },
    { text: "And the retry count", steer: true },
  ]);
});

test("Follow-Up Messages set to Queue: Send mid-turn queues too, and names the keys", async () => {
  setComposerSettings({ followUpMode: "queue" });
  const { sent } = await composer(chat(true), "Also cover the timeout");
  const send = host.querySelector<HTMLButtonElement>("button.acpmux-send")!;
  expect(send.title).toBe("↵ queue · ⌘↵ steer");
  await act(async () => send.click());
  expect(sent).toEqual([{ text: "Also cover the timeout", steer: false }]);
});

test("Follow-Up Messages set to Queue leaves an idle chat's Return alone", async () => {
  setComposerSettings({ followUpMode: "queue" });
  const { field, sent } = await composer(chat(false), "Add retries");
  await press(field, {});
  // Idle, an agent that steers still sends as a steer (it starts a turn when none runs).
  expect(sent).toEqual([{ text: "Add retries", steer: true }]);
});
