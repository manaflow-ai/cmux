// A chat shown again draws its sign-in state from its last answer (sessionAuth.ts `useSessionAuth`):
// no "Checking…" between, and a fresh answer that says the same renders the pane no second time
// before the chat's first frame paints (settled page, Leo 2026-11-21).
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { type ReadSessionAuth, useSessionAuth } from "./sessionAuth";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, key in scope ? scope[key] : undefined);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

type Seen = { sessionId: string; state: string; pending: boolean };

// A new selection reads its sign-in after its frame paints (afterNextPaint.ts): a task later here.
// The render's effects run as its act ends, so the wait for the read is an act of its own.
const show = async (node: ReactNode) => {
  await act(async () => root!.render(node));
  // fixed-wait: the read is scheduled by afterNextPaint's timer and answers on a promise; no DOM or
  // event marks it, so the test waits past that timer as the page would.
  await act(() => new Promise((resolve) => setTimeout(resolve, 5)));
};

test("a chat shown again draws its last answer at once, and the same answer renders nothing more", async () => {
  const answers: Record<string, unknown> = {
    a: { state: "ready", source: "authCheck", fromSessionId: "a" },
    b: { state: "signedOut", source: "authCheck", fromSessionId: "b" },
  };
  const read: ReadSessionAuth = async (query) => answers[(query as { sessionId: string }).sessionId];
  const seen: Seen[] = [];
  function Probe({ sessionId }: { sessionId: string }) {
    const { auth, pending } = useSessionAuth({ sessionId }, read);
    seen.push({ sessionId, state: auth.state, pending });
    return null;
  }
  root = createRoot(installDom());
  for (const sessionId of ["a", "b"]) await show(<Probe sessionId={sessionId} />);
  expect(seen.filter((s) => s.sessionId === "a").at(-1)).toMatchObject({ state: "ready", pending: false });
  expect(seen.filter((s) => s.sessionId === "b").at(-1)).toMatchObject({ state: "signedOut", pending: false });

  seen.length = 0;
  await show(<Probe sessionId="a" />);
  // Every render of the chat shown again has its answer: none waits, and the probe's equal answer
  // adds no render of its own.
  expect(seen.every((s) => s.sessionId === "a" && s.state === "ready" && !s.pending)).toBe(true);
  expect(seen.length).toBe(1);

  // An answer that changed still shows.
  answers.b = { state: "ready", source: "authCheck", fromSessionId: "b" };
  await show(<Probe sessionId="b" />);
  expect(seen.at(-1)).toMatchObject({ sessionId: "b", state: "ready", pending: false });
});
