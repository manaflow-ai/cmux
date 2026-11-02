// Ctrl-B's answer earns a notice (conversation/backgroundNotice.ts): the work moved, or it stayed in
// the foreground after all, or acpmux found nothing in the foreground, refused, never answered, or
// the connection to it was lost. The notice
// leaves on the next key or click, with a newer request, or when the chat changes. The real pane is covered by
// test/agent-pane-ctrl-b-background.test.ts.
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import {
  BACKGROUND_CHECK_MS,
  BACKGROUND_NOTICE_TEXT,
  type BackgroundNotice,
  backgroundNotice,
  useBackgroundNotice,
} from "./backgroundNotice";
import { AcpmuxRpcError } from "../handoff/protocol";

describe("backgroundNotice", () => {
  test("work that moved says so, as does an answer that leaves `backgrounded` out", () => {
    expect(backgroundNotice({ answer: { backgrounded: true } })).toBe("moved");
    expect(backgroundNotice({ answer: {} })).toBe("moved");
  });

  test("nothing in the foreground to move", () => {
    expect(backgroundNotice({ answer: { backgrounded: false } })).toBe("nothing");
  });

  test("a refusal: acpmux says the chat can't (another harness, a peer's connection)", () => {
    const invalid = new AcpmuxRpcError({ code: -32602, message: "invalid params" });
    expect(backgroundNotice({ error: invalid })).toBe("refused");
    expect(backgroundNotice({ error: new Error() })).toBe("refused");
    expect(backgroundNotice({ error: undefined })).toBe("refused");
  });

  test("no answer in time: the work is still running", () => {
    expect(backgroundNotice({ error: Object.assign(new Error(), { code: "native.timed_out" }) })).toBe("timedOut");
  });

  test("a connection that is down when asked is lost, not a refusal", () => {
    expect(backgroundNotice({ error: Object.assign(new Error(), { code: "native.not_connected" }) })).toBe(
      "disconnected",
    );
  });

  test("a connection that closed mid-request is lost, not a timeout", () => {
    // direct.ts rejectPending keeps the timeout code other callers read, and names the reason.
    const interrupted = Object.assign(new Error(), { code: "native.timed_out", reason: "interrupted" });
    expect(backgroundNotice({ error: interrupted })).toBe("disconnected");
  });

  test("each notice has its own string", () => {
    const keys = Object.values(BACKGROUND_NOTICE_TEXT);
    expect(keys).toHaveLength(6);
    expect(new Set(keys).size).toBe(6);
  });
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
type Hook = ReturnType<typeof useBackgroundNotice>;
let latest: Hook | undefined;

function Probe({ sessionId }: { sessionId: string | undefined }) {
  latest = useBackgroundNotice(sessionId);
  return null;
}

async function mount(sessionId: string | undefined): Promise<void> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  await act(async () => {
    root = createRoot(dom!.window.document.getElementById("root")!);
    root.render(<Probe sessionId={sessionId} />);
  });
}

async function rerender(sessionId: string | undefined): Promise<void> {
  await act(async () => root!.render(<Probe sessionId={sessionId} />));
}

/// Tracks `request` and lets it settle.
async function track(request: Promise<unknown>, stillForeground?: () => boolean): Promise<void> {
  await act(async () => {
    latest!.track(request, stillForeground);
    await request.catch(() => undefined);
  });
}

const notice = (): BackgroundNotice | undefined => latest?.notice;
const timedOut = () => Promise.reject(Object.assign(new Error(), { code: "native.timed_out" }));

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  latest = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

describe("useBackgroundNotice", () => {
  test("shows the notice the answer earns", async () => {
    await mount("chat-1");
    await track(Promise.resolve({ backgrounded: false }));
    expect(notice()).toBe("nothing");
    await track(Promise.resolve({ backgrounded: true }));
    expect(notice()).toBe("moved");
    await track(timedOut());
    expect(notice()).toBe("timedOut");
  });

  test("a missing request (no connection to ask) is a lost connection", async () => {
    await mount("chat-1");
    await act(async () => {
      latest!.track(undefined);
      await Promise.resolve();
    });
    expect(notice()).toBe("disconnected");
  });

  test("a held key's repeats and a modifier alone leave it", async () => {
    await mount("chat-1");
    await track(Promise.resolve({ backgrounded: false }));
    expect(notice()).toBe("nothing");
    await act(async () => {
      dom!.window.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "b", ctrlKey: true, repeat: true }));
      for (const key of ["Control", "Meta", "Alt", "Shift"])
        dom!.window.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key }));
    });
    expect(notice()).toBe("nothing");
  });

  test("the next key or click clears it", async () => {
    await mount("chat-1");
    await track(Promise.resolve({ backgrounded: false }));
    expect(notice()).toBe("nothing");
    await act(async () => {
      dom!.window.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "a" }));
    });
    expect(notice()).toBeUndefined();
    await track(timedOut());
    expect(notice()).toBe("timedOut");
    await act(async () => {
      dom!.window.dispatchEvent(new dom!.window.Event("pointerdown"));
    });
    expect(notice()).toBeUndefined();
  });

  test("an older request's late answer does not replace a newer one's", async () => {
    await mount("chat-1");
    let answerFirst: (value: unknown) => void = () => {};
    const first = new Promise((resolve) => (answerFirst = resolve));
    await act(async () => latest!.track(first));
    await track(timedOut());
    expect(notice()).toBe("timedOut");
    await act(async () => {
      answerFirst({ backgrounded: false });
      await first;
    });
    expect(notice()).toBe("timedOut");
  });

  test("another chat clears it, and the old chat's late answer does not show there", async () => {
    await mount("chat-1");
    await track(Promise.resolve({ backgrounded: false }));
    expect(notice()).toBe("nothing");
    await rerender("chat-2");
    expect(notice()).toBeUndefined();

    let answer: (value: unknown) => void = () => {};
    const pending = new Promise((resolve) => (answer = resolve));
    await act(async () => latest!.track(pending));
    await rerender("chat-3");
    await act(async () => {
      answer({ backgrounded: false });
      await pending;
    });
    expect(notice()).toBeUndefined();
  });

  test("a move is checked: work still in the foreground a moment later stayed, work that left moved", async () => {
    await mount("chat-1");
    let running = true;
    await track(Promise.resolve({ backgrounded: true }), () => running);
    expect(notice()).toBe("moved");
    await act(() => new Promise((resolve) => setTimeout(resolve, BACKGROUND_CHECK_MS + 50)));
    expect(notice()).toBe("kept");

    running = false;
    await track(Promise.resolve({ backgrounded: true }), () => running);
    await act(() => new Promise((resolve) => setTimeout(resolve, BACKGROUND_CHECK_MS + 50)));
    expect(notice()).toBe("moved");
  });

  test("a newer request or another chat drops the pending check", async () => {
    await mount("chat-1");
    await track(Promise.resolve({ backgrounded: true }), () => true);
    await track(Promise.resolve({ backgrounded: false }));
    await rerender("chat-2");
    await track(Promise.resolve({ backgrounded: true }), () => true);
    await rerender("chat-3");
    await act(() => new Promise((resolve) => setTimeout(resolve, BACKGROUND_CHECK_MS + 50)));
    expect(notice()).toBeUndefined();
  });
});
