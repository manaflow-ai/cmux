// a823 follow-up to a801 (restore journey --continuity, 204/206): a Claude and a Codex chat each had
// an unsent draft that another client (the CLI, another window) set while the chat's page was
// open. The page's composer was empty and untouched. On quit the host asks every page to settle its
// draft (`pane.wakeState`); the page wrote its empty editor to acpmux and cleared the draft, so it
// came back empty after the relaunch. An untouched composer leaves acpmux's draft alone.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { noChat } from "../src/gallery/fixtures/acpmux";

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
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
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
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
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

async function render(sessionId: string, handle: { current: ComposerHandle | null }) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const snapshot = noChat(
    [],
    sessionId ? { sessionId, summary: { sessionId, harness: "codex", cwd: "/Users/you/src/app", turnCount: 0 } } : {},
  );
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={sessionId}
        chips={Chips}
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
      />,
    ),
  );
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a quit with an untouched empty composer keeps a draft another client set", async () => {
  const durable = new Map<string, string>();
  const writes: { sessionId: string; text: string }[] = [];
  (window as unknown as Record<string, unknown>).cmuxAcpmuxActions = {
    "chat.readDraft": async ({ sessionId }: Record<string, unknown>) => ({
      draft: durable.get(String(sessionId)) ?? null,
    }),
    "chat.writeDraft": async ({ sessionId, text }: Record<string, unknown>) => {
      writes.push({ sessionId: String(sessionId), text: String(text) });
      if (String(text).trim()) durable.set(String(sessionId), String(text));
      else durable.delete(String(sessionId));
    },
  };
  const handle: { current: ComposerHandle | null } = { current: null };
  await render("chat-quit", handle);
  // The durable read answers (no draft yet): the composer is hydrated and empty.
  await act(async () => {
    await tick();
    await tick();
  });
  // Another client saves the chat's draft while the page is open (`_acpmux/draft_set`).
  durable.set("chat-quit", "rj draft rj-claude-0");
  // The quit: the host asks the page to settle its draft.
  await act(async () => {
    await handle.current?.settleDraft();
  });
  expect(writes.filter((write) => write.sessionId === "chat-quit")).toEqual([]);
  expect(durable.get("chat-quit")).toBe("rj draft rj-claude-0");
});
