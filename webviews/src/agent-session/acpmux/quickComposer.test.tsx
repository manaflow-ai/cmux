import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "Node",
    "getSelection",
    "MutationObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
const { proseMirrorGlobals, promptField, typeInto } = await import("./promptFieldTesting");
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  // The diff viewer registers a custom element when App loads.
  customElements: dom.window.customElements,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  // The composer's prompt is a Milkdown (ProseMirror) editor.
  ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// A wide pane, so the default surface shows its session list beside the transcript.
Object.assign(dom.window, {
  matchMedia: () => ({ matches: true, addEventListener() {}, removeEventListener() {} }),
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");

type Host = {
  cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
  cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void };
};
const host = dom.window as unknown as Host;
const container = () => dom.window.document.getElementById("root")!;

/// A new chat (no turns yet) in `sessionId`, or a chat not started when it is undefined.
const snapshot = (sessionId: string | undefined, rows: AcpmuxSnapshot["rows"] = []): AcpmuxSnapshot => ({
  type: "snapshot",
  protocolVersion: 1,
  rows,
  sessions: [{ sessionId: "s0", displayTitle: "An older chat", updatedAt: 1 }],
  sessionId,
  summary: sessionId ? { sessionId, turnCount: rows.length ? 1 : 0 } : undefined,
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
  commands: [{ name: "compact", description: "Summarize the conversation" }],
});

let root: ReturnType<typeof createRoot>;
let calls: [string, Record<string, unknown>][];
/// Mounts the page against a host whose `ready` reply carries `surface`, then shows `first`.
const mount = async (surface: string | undefined, first: AcpmuxSnapshot) => {
  const record =
    (method: string) =>
    async (params: Record<string, unknown>): Promise<unknown> => {
      calls.push([method, params]);
      return null;
    };
  host.cmuxAcpmuxActions = {
    ready: async () => ({ protocolVersion: 1, transport: "test", ...(surface ? { surface } : {}) }),
    "chat.send": record("chat.send"),
    "quick.dismiss": record("quick.dismiss"),
    "quick.openInWindow": record("quick.openInWindow"),
  };
  await act(async () => root.render(createElement(AcpmuxApp)));
  await act(async () => host.cmuxAcpmuxBridge!.receive(first));
  // Milkdown makes its editor a task after the composer mounts.
  await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
};
const methods = () => calls.map(([method]) => method);
const prompt = () => promptField(dom.window.document);
const type = (value: string) => act(async () => typeInto(prompt(), value));
const key = (name: string, init: KeyboardEventInit = {}) =>
  act(async () => {
    prompt().dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...init }),
    );
  });

beforeEach(() => {
  calls = [];
  root = createRoot(container());
});
afterEach(async () => {
  await act(async () => root.unmount());
  delete host.cmuxAcpmuxActions;
});

test("a ready reply with surface quick shows only the composer and its key hints", async () => {
  await mount("quick", snapshot("s1"));
  const page = container();
  expect(page.querySelector(".acpmux-quick")).not.toBeNull();
  expect(page.querySelector(".acpmux-composer")).not.toBeNull();
  // No recent chats, hero, session list or tab header.
  expect(page.querySelector(".acpmux-home-area")).toBeNull();
  expect(page.querySelector(".acpmux-empty")).toBeNull();
  expect(page.querySelector(".acpmux-sidebar")).toBeNull();
  expect(page.querySelector(".acpmux-header")).toBeNull();
  // No transcript before the first prompt.
  expect(page.querySelector(".acpmux-quick-thread")).toBeNull();
  const hints = page.querySelector(".acpmux-quick-keys")!;
  expect([...hints.querySelectorAll(".acpmux-keycap")].map((cap) => cap.textContent)).toEqual(["↩", "⌘↩", "esc"]);
  expect(hints.textContent).toBe("↩send·⌘↩open in window·escclose");
});

test("the quick surface shows the chat's transcript above the composer once it has a prompt", async () => {
  await mount("quick", snapshot("s1"));
  await act(async () =>
    host.cmuxAcpmuxBridge!.receive(snapshot("s1", [{ id: "u1", version: 1, at: 1, kind: "user", text: "hello" }])),
  );
  const thread = container().querySelector(".acpmux-quick-thread")!;
  expect(thread).not.toBeNull();
  expect(thread.querySelector(".acpmux-scroll")).not.toBeNull();
  // The transcript comes before the composer.
  const composer = container().querySelector(".acpmux-composer")!;
  expect(thread.compareDocumentPosition(composer) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
});

test("Escape in the quick surface asks the host to dismiss and keeps the draft", async () => {
  await mount("quick", snapshot("s1"));
  await type("half a thought");
  await key("Escape");
  expect(calls).toEqual([["quick.dismiss", {}]]);
  expect(prompt().value).toBe("half a thought");
});

test("Escape that closes the command menu does not dismiss the quick surface", async () => {
  await mount("quick", snapshot("s1"));
  await type("/");
  expect(container().querySelector(".acpmux-slash-menu")).not.toBeNull();
  await key("Escape");
  expect(container().querySelector(".acpmux-slash-menu")).toBeNull();
  expect(methods()).toEqual([]);
  // A second Escape, with nothing left open, dismisses.
  await key("Escape");
  expect(methods()).toEqual(["quick.dismiss"]);
});

test("⌘Return sends the prompt, then asks to open the chat in a window", async () => {
  await mount("quick", snapshot("s1"));
  await type("summarize the diff");
  await key("Enter", { metaKey: true });
  expect(calls).toEqual([
    ["chat.send", { text: "summarize the diff", attachments: [] }],
    ["quick.openInWindow", { sessionId: "s1" }],
  ]);
  expect(prompt().value).toBe("");
});

test("⌘Return on a first prompt opens the window once its session has started", async () => {
  await mount("quick", snapshot(undefined));
  await type("start something");
  await key("Enter", { metaKey: true });
  expect(methods()).toEqual(["chat.send"]);
  await act(async () =>
    host.cmuxAcpmuxBridge!.receive(
      snapshot("s2", [{ id: "u1", version: 1, at: 1, kind: "user", text: "start something" }]),
    ),
  );
  expect(calls).toEqual([
    ["chat.send", { text: "start something", attachments: [] }],
    ["quick.openInWindow", { sessionId: "s2" }],
  ]);
});

test("a failed send cancels the ⌘Return hand-off, so a later session does not move the chat", async () => {
  await mount("quick", snapshot(undefined));
  host.cmuxAcpmuxActions!["chat.send"] = async (params) => {
    calls.push(["chat.send", params]);
    throw new Error("acpmux went away");
  };
  await type("start something");
  await key("Enter", { metaKey: true });
  await act(async () => host.cmuxAcpmuxBridge!.receive(snapshot("s4")));
  expect(methods()).toEqual(["chat.send"]);
});

test("Escape after ⌘Return cancels the hand-off and dismisses", async () => {
  await mount("quick", snapshot(undefined));
  let land: () => void = () => {};
  host.cmuxAcpmuxActions!["chat.send"] = (params) => {
    calls.push(["chat.send", params]);
    return new Promise((resolve) => (land = () => resolve(null)));
  };
  await type("start something");
  await key("Enter", { metaKey: true });
  await key("Escape");
  await act(async () => {
    land();
    host.cmuxAcpmuxBridge!.receive(snapshot("s5"));
  });
  expect(methods()).toEqual(["chat.send", "quick.dismiss"]);
});

test("⌘Return with an empty composer opens a started chat without sending, and does nothing before one", async () => {
  await mount("quick", snapshot(undefined));
  await key("Enter", { metaKey: true });
  expect(methods()).toEqual([]);
  await act(async () => host.cmuxAcpmuxBridge!.receive(snapshot("s3")));
  expect(methods()).toEqual([]);
  await key("Enter", { metaKey: true });
  expect(calls).toEqual([["quick.openInWindow", { sessionId: "s3" }]]);
});

test("without a surface the pane is unchanged: home lists, session list, no key hints, Escape stays in the page", async () => {
  await mount(undefined, snapshot("s1"));
  const page = container();
  expect(page.querySelector(".acpmux-quick")).toBeNull();
  expect(page.querySelector(".acpmux-quick-keys")).toBeNull();
  expect(page.querySelector(".acpmux-home-area")).not.toBeNull();
  expect(page.querySelector(".acpmux-empty")).not.toBeNull();
  expect(page.querySelector(".acpmux-sidebar")).not.toBeNull();
  expect(page.querySelector(".acpmux-header")).not.toBeNull();
  await type("draft");
  await key("Escape");
  await key("Enter", { metaKey: true });
  expect(methods()).toEqual([]);
  expect(prompt().value).toBe("draft");
});

test("a direct blank pane chat converts with ! without a chooser page", async () => {
  await mount(undefined, snapshot("s1"));
  host.cmuxAcpmuxActions!["tab.open"] = async (params) => {
    calls.push(["tab.open", params]);
  };
  expect(container().querySelector(".acpmux-newtab")).toBeNull();
  await act(async () => prompt().handle.insertTyped("!git status"));
  expect(calls).toContainEqual(["tab.open", { kind: "terminal", text: "git status", run: false }]);
  expect(methods()).not.toContain("chat.send");
});

test("a direct blank chat chooses a recent project inline without treating it as already selected", async () => {
  const fresh = snapshot("s1");
  fresh.sessions = [{ sessionId: "older", cwd: "/src/app", displayTitle: "App", updatedAt: 1 }];
  await mount(undefined, fresh);
  host.cmuxAcpmuxActions!["chat.new"] = async (params) => {
    calls.push(["chat.new", params]);
  };
  await act(async () => (container().querySelector(".acpmux-project-button") as HTMLButtonElement).click());
  const project = container().querySelector(".acpmux-project-menu [role=option]") as HTMLButtonElement;
  expect(project).not.toBeNull();
  await act(async () => project.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })));
  expect(calls).toContainEqual(["chat.new", { cwd: "/src/app" }]);
});
