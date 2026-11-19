// A chat opened or switched to at rest arms no reply check: its turn ended before this page saw it, and the
// check's timer woke the pane at rest (CMUX-571, idle wakeups). A turn the page saw end is still judged.
import { afterEach, expect, test } from "bun:test";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../../test/support/domTeardown";
import type { AcpmuxRow } from "../model";
import { REPLY_SETTLE_MS } from "./replyPainted";
import { useEndedReplyCheck } from "./replyJudge";

let root: Root | undefined;
let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await teardownDom(
    [...saved].map(([key, value]) => [key, value !== undefined, value] as const),
    { window: dom?.window, scope },
  );
  saved.clear();
  dom = undefined;
});

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind,
  ...extra,
});
const chat = (name: string) => [row(`${name}-u`, "user"), row(`${name}-reply`, "assistant", { text: "the answer" })];

function harness() {
  dom = new JSDOM("<!doctype html><html><body><main></main></body></html>");
  const view = dom.window as unknown as Window;
  // The reply check's timers, by their delay.
  const armed: number[] = [];
  view.setTimeout = ((_run: () => void, ms: number) => {
    armed.push(ms);
    return armed.length;
  }) as unknown as typeof view.setTimeout;
  view.clearTimeout = (() => undefined) as typeof view.clearTimeout;
  for (const key of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: view,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.querySelector("main")!);
  function Probe(props: { sessionId: string; rows: AcpmuxRow[]; working: boolean }) {
    const scroller = useRef<HTMLElement>(null);
    const host = useRef<HTMLElement>(null);
    const follow = useRef({ atLatest: true });
    useEndedReplyCheck({ ...props, loading: false, dockSpace: 0, scroller, host, follow });
    return null;
  }
  return {
    render: (sessionId: string, working: boolean) =>
      act(() => root!.render(<Probe sessionId={sessionId} rows={chat(sessionId)} working={working} />)),
    checks: () => armed.filter((ms) => ms === REPLY_SETTLE_MS).length,
  };
}

test("a chat opened, or switched to, with its turn already ended arms no reply check", () => {
  const pane = harness();
  pane.render("A", false);
  pane.render("B", false);
  expect(pane.checks()).toBe(0);
});

test("a turn the page saw working is judged once it ends", () => {
  const pane = harness();
  pane.render("A", true);
  expect(pane.checks()).toBe(0);
  pane.render("A", false);
  expect(pane.checks()).toBe(1);
  // Switched away and back at rest: that turn ended before this page showed it again.
  pane.render("B", false);
  pane.render("A", false);
  expect(pane.checks()).toBe(1);
});
