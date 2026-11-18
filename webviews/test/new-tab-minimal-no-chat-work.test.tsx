// l10n-allow-file: test fixtures.
// Leo 2026-11-18: New Tab sorted every chat, closed ones included, to show 3 to 6 recent ones, and
// built a card for each of about 2,500 child chats, behind a Minimal page that draws no chats: "We
// literally don't even have that as a visible option at all anymore". The chat lists left with the
// templates that drew them (Cards, Default, Threads and Console moved to looks): the page draws no
// chat and reads no chat's preview, however many there are.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
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
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => teardownDom(saved, { scope }));

const noop = () => {};

const entry = (id: string, updatedAt: number, spawnedBy?: string): AcpmuxSessionEntry => ({
  sessionId: id,
  displayTitle: id,
  cwd: "/Users/you/src/atlas",
  updatedAt,
  preview: `what ${id} is doing`,
  ...(spawnedBy ? { spawnedBy } : {}),
});

/// Every read of a chat's `preview` counts: only a chat card read it.
function counted(sessions: AcpmuxSessionEntry[]): { sessions: AcpmuxSessionEntry[]; reads: () => number } {
  let reads = 0;
  const wrapped = sessions.map(
    (session) =>
      new Proxy(session, {
        get(target, key, receiver) {
          if (key === "preview") reads += 1;
          return Reflect.get(target, key, receiver);
        },
      }),
  );
  return { sessions: wrapped, reads: () => reads };
}

test("Minimal, the page's one layout, lists no chats and reads none of their previews", async () => {
  // 6 parents, and 2,500 children under one of them.
  const parents = Array.from({ length: 6 }, (_, index) => entry(`p${index}`, 100 - index));
  const children = Array.from({ length: 2500 }, (_, index) => entry(`c${index}`, 1, "p5"));
  const { sessions, reads } = counted([...parents, ...children]);
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <NewTabScreen
          snapshot={noChat(sessions)}
          lastAgent="claude"
          cwd="/Users/you/src/atlas"
          onCreate={noop}
          onAsk={noop}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
        />,
      ),
    );
    expect(host.querySelector('.nt-screen[data-template="minimal"]')).not.toBeNull();
    expect(host.textContent).not.toContain("p0");
    expect(host.textContent).not.toContain("what p0 is doing");
    expect(reads()).toBe(0);
  } finally {
    await act(async () => root.unmount());
  }
});
