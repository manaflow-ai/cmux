// l10n-allow-file: test fixtures.
// `cmux app chat drive` (chatDrive.ts) on the real composer: a zero from it means the composer did
// not render or change. A forced re-render of the composer counts renders and DOM changes; a run with
// nothing happening counts none; after `end` the probe is null and no observer, listener, frame or
// timer of the run is left; and `begin` refuses a second run, a busy chat, a missing target and a
// typed run over a draft.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { CaptureEnv } from "../src/agent-session/acpmux/chatPerfCapture";
import type { DriveEnv, DriveHost } from "../src/agent-session/acpmux/chatDrive";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Node",
  "Text",
  "Range",
  "Selection",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "InputEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "PointerEvent",
  "FocusEvent",
  "ResizeObserver",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
/// MutationObservers observing now, and window listeners added and not yet removed (the composer's
/// own included: a test compares them with what they were before the run).
let observing = 0;
let windowListeners = 0;
const held = () => ({ observing, windowListeners });

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const w = dom.window as unknown as Record<string, any>;
  // Counts what the drive leaves behind: observers that observe and never disconnect, listeners never removed.
  const Base = w.MutationObserver as typeof MutationObserver;
  w.MutationObserver = class extends Base {
    private on = false;
    observe(target: Node, options?: MutationObserverInit) {
      if (!this.on) observing += 1;
      this.on = true;
      super.observe(target, options);
    }
    disconnect() {
      if (this.on) observing -= 1;
      this.on = false;
      super.disconnect();
    }
  };
  const add = w.addEventListener.bind(w);
  const remove = w.removeEventListener.bind(w);
  w.addEventListener = (...args: Parameters<Window["addEventListener"]>) => {
    windowListeners += 1;
    add(...args);
  };
  w.removeEventListener = (...args: Parameters<Window["removeEventListener"]>) => {
    windowListeners -= 1;
    remove(...args);
  };
  Object.assign(scope, Object.fromEntries(keys.map((key) => [key, w[key]])), {
    IS_REACT_ACT_ENVIRONMENT: true,
    PointerEvent: w.PointerEvent ?? w.MouseEvent,
    ResizeObserver:
      w.ResizeObserver ??
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
const snapshot = (isWorking = false) =>
  ({
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking,
    queue: [],
    canLoadOlder: false,
    catalog: [],
    summary: { sessionId: "s1", harness: "claude", model: "claude-opus-5-5", turnCount: 1 },
  }) as unknown as Snapshot;

let client: import("@tanstack/react-query").QueryClient;

/// The real composer, drawn with `placeholder`: a new one renders it again and changes its DOM.
async function render(placeholder: string) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  client ??= new QueryClient();
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={client}>
        <Composer
          snapshot={snapshot()}
          chips={() => null}
          onSend={() => undefined}
          onStop={() => undefined}
          placeholder={placeholder}
        />
      </QueryClientProvider>,
    );
  });
  await settle();
}

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

/// A page whose frames, timers and observers the test drives by hand (chatPerfCapture.test.ts's).
function fakeEnv() {
  let clock = 0;
  const frames = new Map<number, (time: number) => void>();
  let nextFrame = 1;
  const timers = new Map<number, () => void>();
  let nextTimer = 1;
  const observers = new Map<string, (entries: unknown[]) => void>();
  let visibilityListeners = 0;
  const env: DriveEnv = {
    now: () => clock,
    requestFrame(callback) {
      frames.set(nextFrame, callback);
      return nextFrame++;
    },
    cancelFrame: (handle) => void frames.delete(handle),
    setTimer(callback) {
      timers.set(nextTimer, callback);
      return nextTimer++;
    },
    clearTimer: (handle) => void timers.delete(handle as number),
    visibility: () => "visible",
    onVisibilityChange() {
      visibilityListeners += 1;
      return () => void (visibilityListeners -= 1);
    },
    observe: ((type, onEntries) => {
      observers.set(type, onEntries);
      return { disconnect: () => void observers.delete(type) };
    }) satisfies CaptureEnv["observe"],
    supportedEntryTypes: () => ["layout-shift"],
  };
  return {
    env,
    /// `count` frames, 16 ms apart.
    frames(count: number) {
      for (let index = 0; index < count; index += 1) {
        clock += 16;
        const due = [...frames.values()];
        frames.clear();
        for (const callback of due) callback(clock);
      }
    },
    backstop() {
      for (const run of timers.values()) run();
    },
    observers,
    live: () => ({ frames: frames.size, timers: timers.size, observers: observers.size, visibilityListeners }),
  };
}

const idleHost = (draft = ""): DriveHost => ({
  busy: () => false,
  draft: () => ({ text: draft, attachments: [] }),
});

test("a forced composer render counts renders and DOM changes; a still run counts none", async () => {
  const { ChatDrive } = await import("../src/agent-session/acpmux/chatDrive");
  const { composerProbe } = await import("../src/agent-session/acpmux/composerProbe");
  await render("Ask anything");
  const page = fakeEnv();
  const drive = new ChatDrive();

  // Still: frames pass and nothing in the composer renders or changes.
  const before = held();
  expect(await drive.begin({ seconds: 1 }, idleHost(), page.env)).toMatchObject({ ok: true });
  page.frames(5);
  const still = (await drive.end()) as Record<string, any>;
  expect(still.totals.frames).toBe(5);
  expect(still.totals.composer_renders).toBe(0);
  expect(still.totals.composer_mutations).toBe(0);
  expect(still.frames.every((frame: { composer_renders: number }) => frame.composer_renders === 0)).toBe(true);
  // After end: the probe is null and the run left no observer, listener, frame or timer.
  expect(composerProbe.render).toBeNull();
  expect(held()).toEqual(before);
  expect(page.live()).toEqual({ frames: 0, timers: 0, observers: 0, visibilityListeners: 0 });

  // Churn: the pane hands the composer a new prop mid-run; it renders and its DOM changes.
  expect(await drive.begin({ seconds: 1 }, idleHost(), page.env)).toMatchObject({ ok: true });
  page.frames(2);
  await render("Reply in this session…");
  page.frames(2);
  page.observers.get("layout-shift")?.([{ value: 0.25 }, { value: 0.5, hadRecentInput: true }]);
  page.frames(1);
  const churn = (await drive.end()) as Record<string, any>;
  expect(churn.totals.composer_renders).toBeGreaterThan(0);
  expect(churn.totals.composer_renders_by.composer).toBeGreaterThan(0);
  expect(churn.totals.composer_mutations).toBeGreaterThan(0);
  expect(churn.totals.mutation_nodes).toBeGreaterThan(0);
  // The frame after the render is where it shows; the ones before it are still.
  expect(churn.frames.slice(0, 2).map((frame: { composer_renders: number }) => frame.composer_renders)).toEqual([0, 0]);
  expect(churn.frames[2].composer_renders).toBeGreaterThan(0);
  expect(churn.frames[2].composer_mutations).toBeGreaterThan(0);
  // A shift with recent input is the reader's own; only the other counts.
  expect(churn.totals.layout_shift).toBe(0.25);
  expect(churn.frames.at(-1).layout_shift).toBe(0.25);
  expect(churn.typed).toBeNull();
  expect(churn.layouts).toBeNull();
  expect(typeof churn.layouts_unavailable).toBe("string");

  expect(composerProbe.render).toBeNull();
  expect(page.live()).toEqual({ frames: 0, timers: 0, observers: 0, visibilityListeners: 0 });
  // A render after the run is counted nowhere.
  await render("Ask anything");
  expect(await drive.end()).toEqual({ error: "not_running" });
});

test("begin refuses a second run, a busy chat, a missing or unsafe target and a typed run over a draft", async () => {
  const { ChatDrive } = await import("../src/agent-session/acpmux/chatDrive");
  const { composerProbe } = await import("../src/agent-session/acpmux/composerProbe");
  await render("Ask anything");
  const page = fakeEnv();
  const drive = new ChatDrive();
  const before = held();
  expect(await drive.begin({ seconds: 1 }, idleHost(), page.env)).toMatchObject({ ok: true });
  expect(await drive.begin({ seconds: 1 }, idleHost(), page.env)).toEqual({ error: "running" });
  await drive.end();

  const busy: DriveHost = { ...idleHost(), busy: () => true };
  expect(await drive.begin({ seconds: 1 }, busy, page.env)).toEqual({ error: "busy" });
  expect(await drive.begin({ seconds: 1, allow_busy: true }, busy, page.env)).toMatchObject({ ok: true });
  await drive.end();

  expect(await drive.begin({ seconds: 1, target: { sent_image: 1 } }, idleHost(), page.env)).toEqual({
    error: "no_target",
  });
  expect(await drive.begin({ seconds: 1, target: { tool_screenshot: 1 } }, idleHost(), page.env)).toEqual({
    error: "no_target",
  });
  // A test id is an id, never a selector: one that could close the attribute matches nothing.
  const marked = dom.window.document.createElement("div");
  marked.setAttribute("data-testid", "x");
  host.append(marked);
  expect(await drive.begin({ seconds: 1, target: { test_id: 'x"],*,[a="' } }, idleHost(), page.env)).toEqual({
    error: "no_target",
  });

  const typing = { text: "hello", allow_draft: false };
  expect(await drive.begin({ seconds: 1, type: typing }, idleHost("half a thought"), page.env)).toEqual({
    error: "draft_not_empty",
  });
  const noComposer: DriveHost = { busy: () => false, draft: () => undefined };
  expect(await drive.begin({ seconds: 1 }, noComposer, page.env)).toEqual({ error: "no_composer" });
  // No refusal installs anything.
  expect(composerProbe.render).toBeNull();
  expect(held()).toEqual(before);
  expect(page.live()).toEqual({ frames: 0, timers: 0, observers: 0, visibilityListeners: 0 });
});

test("a host that never ends the run: the page ends it itself and the late end gets its report", async () => {
  const { ChatDrive } = await import("../src/agent-session/acpmux/chatDrive");
  const { composerProbe } = await import("../src/agent-session/acpmux/composerProbe");
  await render("Ask anything");
  const page = fakeEnv();
  const drive = new ChatDrive();
  const before = held();
  expect(await drive.begin({ seconds: 1 }, idleHost(), page.env)).toMatchObject({ ok: true });
  page.frames(3);
  page.backstop();
  expect(drive.active).toBe(false);
  expect(composerProbe.render).toBeNull();
  expect(held()).toEqual(before);
  expect(page.live()).toEqual({ frames: 0, timers: 0, observers: 0, visibilityListeners: 0 });
  const late = (await drive.end()) as Record<string, any>;
  expect(late.ended_by).toBe("backstop");
  expect(late.totals.frames).toBe(3);
  expect(await drive.end()).toEqual({ error: "not_running" });
  // state() stays callable once the run is over.
  expect(drive.state()).toMatchObject({ hovered: null, card_open: null, running: false });
});

/// Dispatches `event` at `target` as the engine's own input (isTrusted), which a test's dispatchEvent
/// never is: jsdom marks an event trusted only on its own internal path.
function dispatchTrusted(target: EventTarget, event: Event) {
  const impl = (wrapper: object) =>
    (wrapper as Record<symbol, any>)[Object.getOwnPropertySymbols(wrapper).find((key) => key.description === "impl")!];
  const inner = impl(event);
  inner.isTrusted = true;
  impl(target)._dispatch(inner);
}

test("typed text that no person types key by key, or that would open shell mode, is refused", async () => {
  const { ChatDrive, MAX_TYPE_UNITS } = await import("../src/agent-session/acpmux/chatDrive");
  const { composerProbe } = await import("../src/agent-session/acpmux/composerProbe");
  await render("Ask anything");
  const page = fakeEnv();
  const drive = new ChatDrive();
  const before = held();
  const begin = (text: unknown, draft = "") =>
    drive.begin({ seconds: 1, type: { text, allow_draft: true } }, idleHost(draft), page.env);
  for (const text of ["two\nlines", "tab\there", "nul\u0000", "del\u007F", "c1\u0085", "line sep", "para sep"])
    expect(await begin(text)).toEqual({ error: "bad_text" });
  expect(await begin("a".repeat(MAX_TYPE_UNITS + 1))).toEqual({ error: "bad_text" });
  expect(await begin(42)).toEqual({ error: "bad_text" });
  // `!` first into an empty prompt is shell mode; after a draft it is a character.
  expect(await begin("!rm -rf /")).toEqual({ error: "shell_prefix" });
  expect(composerProbe.render).toBeNull();
  expect(held()).toEqual(before);
  expect(page.live()).toEqual({ frames: 0, timers: 0, observers: 0, visibilityListeners: 0 });
  expect(await begin("!", "a draft")).toMatchObject({ ok: true });
  await drive.end();
  expect(await begin("a".repeat(MAX_TYPE_UNITS))).toMatchObject({ ok: true });
  await drive.end();
});

test("a person's key during the run stops the typing and marks the run person_active", async () => {
  const { ChatDrive } = await import("../src/agent-session/acpmux/chatDrive");
  const { COMPOSER_EDITOR } = await import("../src/agent-session/acpmux/composerSelectors");
  await render("Ask anything");
  const page = fakeEnv();
  const drive = new ChatDrive();
  // jsdom has no text insertion: each accepted character is the editor's insert.
  const inserted: string[] = [];
  const doc = dom.window.document as unknown as { execCommand(command: string, ui: boolean, text: string): boolean };
  doc.execCommand = (_command, _ui, text) => {
    inserted.push(text);
    return true;
  };
  expect(
    await drive.begin({ seconds: 1, type: { text: "abcdef", allow_draft: false } }, idleHost(), page.env),
  ).toMatchObject({ ok: true });
  page.frames(2);
  const editor = dom.window.document.querySelector(COMPOSER_EDITOR)!;
  // A script's key is no person's.
  editor.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "x", bubbles: true }));
  page.frames(1);
  expect(drive.state().person_active).toBe(false);
  expect(drive.personActive().typing_ms_ago).toBeNull();
  dispatchTrusted(editor, new dom.window.KeyboardEvent("keydown", { key: "x", bubbles: true }));
  expect(drive.state().person_active).toBe(true);
  expect(drive.personActive().typing_ms_ago).toBe(0);
  page.frames(3);
  const report = (await drive.end()) as Record<string, any>;
  expect(inserted).toEqual(["a", "b", "c"]);
  expect(report.typed).toBe(3);
  expect(report.type_stopped).toBe("person");
  expect(report.person_active).toBe(true);
  expect(report.person_active_by).toBe("key");
  // Still readable once the run is over.
  expect(drive.state().person_active).toBe(true);
});

test("a run that ends before its text is typed says it was cut off, and how much of it went in", async () => {
  const { ChatDrive } = await import("../src/agent-session/acpmux/chatDrive");
  await render("Ask anything");
  const doc = dom.window.document as unknown as { execCommand(command: string, ui: boolean, text: string): boolean };
  doc.execCommand = () => true;
  for (const [text, frames, typed, stopped] of [
    ["abcdef", 2, 2, "time_up"],
    ["ab", 4, 2, undefined],
  ] as const) {
    const page = fakeEnv();
    const drive = new ChatDrive();
    expect(await drive.begin({ seconds: 1, type: { text, allow_draft: false } }, idleHost(), page.env)).toMatchObject({
      ok: true,
    });
    page.frames(frames);
    const report = (await drive.end()) as Record<string, any>;
    expect(report.typed).toBe(typed);
    expect(report.type_asked).toBe(text.length);
    expect(report.type_stopped).toBe(stopped);
  }
});

test("typing over a draft starts at its end, never over the person's selection", async () => {
  const { ChatDrive } = await import("../src/agent-session/acpmux/chatDrive");
  const { COMPOSER_EDITOR } = await import("../src/agent-session/acpmux/composerSelectors");
  await render("Ask anything");
  const document = dom.window.document;
  const editor = document.querySelector(COMPOSER_EDITOR)!;
  editor.appendChild(document.createTextNode("hello"));
  // The person's selection over the draft, which an insert there would replace.
  const selected = document.createRange();
  selected.selectNodeContents(editor);
  document.getSelection()!.removeAllRanges();
  document.getSelection()!.addRange(selected);
  const atInsert: { collapsed: boolean; atEnd: boolean }[] = [];
  const doc = document as unknown as { execCommand(command: string, ui: boolean, text: string): boolean };
  doc.execCommand = () => {
    const selection = document.getSelection()!;
    const end = document.createRange();
    end.selectNodeContents(editor);
    end.collapse(false);
    const range = selection.getRangeAt(0);
    atInsert.push({
      collapsed: selection.isCollapsed,
      atEnd: range.compareBoundaryPoints(dom.window.Range.END_TO_END, end) === 0,
    });
    return true;
  };
  const page = fakeEnv();
  const drive = new ChatDrive();
  expect(
    await drive.begin({ seconds: 1, type: { text: "x", allow_draft: true } }, idleHost("hello"), page.env),
  ).toMatchObject({ ok: true });
  page.frames(2);
  await drive.end();
  expect(atInsert).toEqual([{ collapsed: true, atEnd: true }]);
});

test("a person's key the run ends on, before a frame acts on it, still stops the typing as the person's", async () => {
  const { ChatDrive } = await import("../src/agent-session/acpmux/chatDrive");
  const { COMPOSER_EDITOR } = await import("../src/agent-session/acpmux/composerSelectors");
  await render("Ask anything");
  const page = fakeEnv();
  const drive = new ChatDrive();
  const doc = dom.window.document as unknown as { execCommand(command: string, ui: boolean, text: string): boolean };
  doc.execCommand = () => true;
  expect(
    await drive.begin({ seconds: 1, type: { text: "abcdef", allow_draft: false } }, idleHost(), page.env),
  ).toMatchObject({ ok: true });
  page.frames(2);
  dispatchTrusted(
    dom.window.document.querySelector(COMPOSER_EDITOR)!,
    new dom.window.KeyboardEvent("keydown", { key: "x", bubbles: true }),
  );
  // No frame between the key and the end: the typing's own check never ran.
  const report = (await drive.end()) as Record<string, any>;
  expect(report.typed).toBe(2);
  expect(report.type_stopped).toBe("person");
});
