// Lucas 2026-10-19: picking another provider's model in the composer is a harness switch, which
// starts a new session; the composer swapped to that session's (empty) saved draft and the typed
// prompt vanished. During a switch the prompt stays and becomes the new session's draft. Moving to
// another chat still shows that chat's own draft.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { draftTextActions } from "../src/agent-session/acpmux/draftTextActions";

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

async function render(sessionId: string | undefined, props: { draft?: string; switching?: boolean } = {}) {
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
        draft={props.draft}
        switching={props.switching}
      />,
    ),
  );
}

const prompt = () => host.querySelector('[role="combobox"]')?.textContent ?? "";

test("a harness switch keeps the typed prompt through the new session", async () => {
  await render("chat-a", { draft: "compare these cars" });
  expect(prompt()).toBe("compare these cars");
  // The pick: the old chat is hidden while the new session starts, then it arrives.
  await render("", { switching: true });
  expect(prompt()).toBe("compare these cars");
  await render("chat-b", { switching: true });
  expect(prompt()).toBe("compare these cars");
  // The switch settles on the new session; a later move to another chat shows that chat's draft.
  await render("chat-b");
  expect(prompt()).toBe("compare these cars");
  await render("chat-c");
  expect(prompt()).toBe("");
});

test("a switch that ends in the same render as its session change still keeps the prompt", async () => {
  await render("chat-a", { draft: "compare these cars" });
  await render("", { switching: true });
  // The intent clears in the batch that brings the new session.
  await render("chat-b");
  expect(prompt()).toBe("compare these cars");
});

test("the handshake draft survives the first session assignment but not a later chat switch", async () => {
  await render(undefined);
  await render(undefined, { draft: "from the relaunch handshake" });
  await render("handshake-a", { draft: "from the relaunch handshake" });
  expect(prompt()).toBe("from the relaunch handshake");
  await render("handshake-b");
  expect(prompt()).toBe("");
});

test("moving to a chat with its own draft mid-switch keeps that chat's draft", async () => {
  const { writePersistedDraft } = await import("../src/agent-session/acpmux/composerDraft");
  writePersistedDraft("chat-d", "my other draft");
  await render("chat-a", { draft: "compare these cars" });
  await render("chat-d", { switching: true });
  expect(prompt()).toBe("my other draft");
});

test("moving to another chat shows that chat's draft, not the typed prompt", async () => {
  await render("chat-a", { draft: "compare these cars" });
  expect(prompt()).toBe("compare these cars");
  await render("chat-c");
  expect(prompt()).toBe("");
});

for (const source of ["initial cache", "carried prompt"]) {
  for (const mode of ["daemon null", "daemon empty", "native empty"]) {
    test(`an authoritative ${mode} clears a stale ${source} through hydration`, async () => {
      const sessionId = `clear-${source}-${mode}`;
      const writes: { sessionId: string; text: string }[] = [];
      const page = dom.window as unknown as { cmuxAcpmuxActions?: ReturnType<typeof draftTextActions> };
      const { readPersistedDraft, settlePendingDraftWrites } =
        await import("../src/agent-session/acpmux/composerDraft");
      if (source === "carried prompt") {
        await render(`source-${sessionId}`, { draft: "stale carried text" });
        await render(undefined, { switching: true });
      } else {
        dom.window.localStorage.setItem(`cmux.acpmux.composer-draft.${encodeURIComponent(sessionId)}`, "stale cache");
      }
      page.cmuxAcpmuxActions = draftTextActions(
        {
          readDraft: async () =>
            mode === "native empty" ? undefined : { sessionId, draft: mode === "daemon null" ? null : "" },
          writeDraft: async (id, text) => {
            writes.push({ sessionId: id, text });
          },
        },
        async (method) => (method === "chat.draftText.get" ? "" : undefined),
      );
      try {
        await render(sessionId, source === "initial cache" ? { draft: "stale handshake" } : { switching: true });
        await settlePendingDraftWrites();
        expect(prompt()).toBe("");
        expect(readPersistedDraft(sessionId)).toBeUndefined();
        expect(writes.filter((write) => write.sessionId === sessionId).every((write) => write.text === "")).toBe(true);
      } finally {
        await settlePendingDraftWrites();
        delete page.cmuxAcpmuxActions;
        dom.window.localStorage.clear();
      }
    });
  }
}
