// cmux#57157: with Cloud picked, the composer's Bypass permissions (and its agent and model) went back
// to the default on a new workspace, a new tab or a split, and Runs On could go back to This Mac.
// Every one of those opens an agent page: a fresh one, or one the app readied before the pick (the
// New Tab spare, an idle New Tab page) that it adopts. The Cloud picks lived in one page's memory, and
// the place was read once per chat, so a readied page kept what it read when it loaded. Every new
// chat's composer picks now live in the store every agent page shares (newChatPicks.ts), and a page
// hears a pick another page made (`storage`). A new page here is a fresh copy of the modules over the
// same storage.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "localStorage", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });

beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterEach(() => dom.window.localStorage.clear());

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Page = {
  mode: typeof import("../src/agent-session/acpmux/cloudModePick");
  agent: typeof import("../src/agent-session/acpmux/cloudAgentPick");
  place: typeof import("../src/agent-session/acpmux/lastNewChatPlace");
};

let pages = 0;
/// An agent page: its own module instances (its own memory) over the storage every page shares.
async function loadPage(): Promise<Page> {
  pages += 1;
  const tag = `?page=${pages}`;
  return {
    mode: await import(`../src/agent-session/acpmux/cloudModePick.ts${tag}`),
    agent: await import(`../src/agent-session/acpmux/cloudAgentPick.ts${tag}`),
    place: await import(`../src/agent-session/acpmux/lastNewChatPlace.ts${tag}`),
  };
}

/// What WebKit and Chromium tell every other page of the origin when one page writes its storage.
function otherPageWrote(key: string | null) {
  dom.window.dispatchEvent(new dom.window.StorageEvent("storage", { key }));
}

/// The person's picks on the page they last used: Cloud, Codex on its model, Bypass permissions.
function pickOn(page: Page) {
  page.place.rememberNewChatPlace({ kind: "cloud" });
  page.agent.holdCloudAgentPick({ harness: "codex", model: "gpt-6" });
  page.mode.holdCloudModePick("codex", "agent-full-access");
  for (const key of [
    "cmux.agentPane.lastNewChatPlace",
    "cmux.agentPane.newChat.cloudAgent",
    "cmux.agentPane.newChat.cloudMode",
  ])
    otherPageWrote(key);
}

function expectPicks(page: Page) {
  expect(page.place.lastNewChatPlace()).toEqual({ kind: "cloud" });
  expect(page.agent.cloudAgentPick()).toEqual({ harness: "codex", model: "gpt-6" });
  expect(page.mode.cloudStartModePick("codex")).toEqual({ mode: "agent-full-access" });
  // The Cloud send from the new page carries the same agent, model and mode.
  expect(page.mode.cloudSendAgent("codex", "codex", "gpt-6")).toEqual({
    harness: "codex",
    model: "gpt-6",
    mode: "agent-full-access",
  });
}

/// The place as App draws it (`useLastNewChatPlace`), on a page mounted before the pick.
async function mountPlace(page: Page) {
  const { createRoot } = await import("react-dom/client");
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const shown: unknown[] = [];
  function Place() {
    shown.push(page.place.useLastNewChatPlace());
    return null;
  }
  let root: Root | undefined;
  await act(async () => {
    root = createRoot(host);
    root.render(<Place />);
  });
  return {
    last: () => shown.at(-1),
    unmount: () => act(() => root?.unmount()),
  };
}

// How each path's new chat gets its page (the app's NewTabPage, NewTabSparePool, AgentTabs):
// Cmd+N, Cmd+T, Cmd+D and Cmd+Shift+D open the New Tab page, mostly by adopting a page the app
// readied before (the spare, an idle New Tab page); New Agent Chat, `cmux agent new-chat` and
// New Cloud Chat load a chat page of their own.
const PATHS = [
  ["new workspace (Cmd+N)", "readied"],
  ["new tab (Cmd+T)", "readied"],
  ["split right (Cmd+D)", "readied"],
  ["split down (Cmd+Shift+D)", "readied"],
  ["new tab, no spare ready", "fresh"],
  ["palette New Agent Chat", "fresh"],
  ["cmux agent new-chat", "fresh"],
  ["New Cloud Chat", "fresh"],
] as const;

for (const [path, arrives] of PATHS) {
  test(`${path}: the new chat keeps Cloud, its agent, model and permission mode`, async () => {
    const used = await loadPage();
    // A readied page is loaded, and draws its place, before the person picks on another page.
    const next = arrives === "readied" ? await loadPage() : undefined;
    const drawn = next ? await mountPlace(next) : undefined;
    expect(drawn?.last()).toBeUndefined();
    await act(async () => pickOn(used));
    const page = next ?? (await loadPage());
    expectPicks(page);
    if (drawn) {
      expect(drawn.last()).toEqual({ kind: "cloud" });
      drawn.unmount();
    }
  });
}

test("Auto as the place carries over, and the newest pick on any page wins", async () => {
  const first = await loadPage();
  const second = await loadPage();
  const drawn = await mountPlace(second);
  await act(async () => {
    first.place.rememberNewChatPlace({ kind: "auto" });
    otherPageWrote("cmux.agentPane.lastNewChatPlace");
  });
  expect(drawn.last()).toEqual({ kind: "auto" });
  first.mode.holdCloudModePick("claude", "auto");
  second.mode.holdCloudModePick("claude", "bypassPermissions");
  const third = await loadPage();
  expect(third.place.lastNewChatPlace()).toEqual({ kind: "auto" });
  expect(third.mode.cloudStartModePick("claude")).toEqual({ mode: "bypassPermissions" });
  // A mode picked for another agent never applies to this one.
  expect(third.mode.cloudStartModePick("codex")).toEqual({});
  drawn.unmount();
});

test("a value this build can't read is no pick; a store that refuses keeps the pick on its page", async () => {
  dom.window.localStorage.setItem("cmux.agentPane.newChat.cloudMode", "not json");
  dom.window.localStorage.setItem("cmux.agentPane.newChat.cloudAgent", '{"harness":""}');
  const page = await loadPage();
  expect(page.mode.cloudStartModePick("claude")).toEqual({});
  expect(page.agent.cloudAgentPick()).toBeUndefined();
  const refusing = {
    getItem: () => null,
    setItem: () => {
      throw new Error("full");
    },
  };
  page.place.rememberNewChatPlace({ kind: "cloud" }, refusing);
  expect(page.place.lastNewChatPlace(refusing)).toEqual({ kind: "cloud" });
});
