// Leo, 2026-11-21: "workspace switch, opening a recent workspace, chat switch and restart reach a
// settled page (zero layout shift after first paint, streaming included) within 2x of a derived
// bound." A chat switch read the new chat's sign-in in the effect of the render that drew it. A
// local daemon answers at once, so the reply rendered the whole pane again before the switch's
// first frame painted (bench/settled-page.bench.ts, chat_switch). The read of a new selection now
// goes out after that frame (`afterNextPaint`); a recheck of the same selection still reads at once.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
/// Frames run only when the test paints them.
const frames = new Map<number, () => void>();
let nextFrame = 1;
const paint = () => {
  const due = [...frames.values()];
  frames.clear();
  for (const run of due) run();
};

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    requestAnimationFrame: (run: () => void) => {
      const id = nextFrame++;
      frames.set(id, run);
      return id;
    },
    cancelAnimationFrame: (id: number) => frames.delete(id),
  });
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window });
});

/// Yields one task at a time until `ready` holds: the read a painted frame schedules runs in a task
/// after that frame, so a test waits for the read it asserts on next, never a fixed time.
const until = async (ready: () => boolean) => {
  for (let turn = 0; !ready(); turn++) {
    if (turn > 1000) throw new Error("the awaited read never came");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

test("a switched chat reads its sign-in after the frame that draws it", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useSessionAuth } = await import("../src/agent-session/acpmux/sessionAuth");
  const reads: string[] = [];
  const read = async (query: { sessionId: string } | { target: unknown }) => {
    reads.push("sessionId" in query ? query.sessionId : "target");
    return { state: "ready" };
  };
  const Probe = ({ sessionId }: { sessionId: string }) => {
    useSessionAuth({ sessionId }, read);
    return null;
  };
  const root: Root = createRoot(document.getElementById("root")!);
  try {
    await act(async () => root.render(<Probe sessionId="chat-a" />));
    await act(async () => {
      paint();
      await until(() => reads.length === 1);
    });
    expect(reads).toEqual(["chat-a"]);

    // The switch renders and commits; its sign-in read waits for the frame that shows it (before
    // the change the read went out in the commit's own effect).
    await act(async () => root.render(<Probe sessionId="chat-b" />));
    expect(reads).toEqual(["chat-a"]);
    await act(async () => {
      paint();
      await until(() => reads.length === 2);
    });
    expect(reads).toEqual(["chat-a", "chat-b"]);
  } finally {
    act(() => root.unmount());
  }
});

test("a switch away before the frame never reads the chat it left", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useSessionAuth } = await import("../src/agent-session/acpmux/sessionAuth");
  const reads: string[] = [];
  const read = async (query: { sessionId: string } | { target: unknown }) => {
    reads.push("sessionId" in query ? query.sessionId : "target");
    return { state: "ready" };
  };
  const Probe = ({ sessionId }: { sessionId: string }) => {
    useSessionAuth({ sessionId }, read);
    return null;
  };
  const root: Root = createRoot(document.getElementById("root")!);
  try {
    await act(async () => root.render(<Probe sessionId="chat-a" />));
    await act(async () => root.render(<Probe sessionId="chat-b" />));
    expect(reads).toEqual([]);
    await act(async () => {
      paint();
      await until(() => reads.includes("chat-b"));
    });
    expect(reads).toEqual(["chat-b"]);
  } finally {
    act(() => root.unmount());
  }
});
