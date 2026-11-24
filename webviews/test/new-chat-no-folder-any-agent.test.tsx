// cmux#40938, for every agent: a new chat in a fresh workspace (its tab sits at `~`, the chat has
// No folder) must start, whichever agent it is for, and cmux must never start it in `~` by itself.
// Before, two paths did: a start that named the tab's inherited folder (the composer chips' agent
// or model pick, the slash command list) sent `session/new {cwd: ~}`, and the harness switch then
// reused that refused folder for the next start of any agent, Enter's included. The pane's relay
// refuses the home folder until the person answers the home question, so every agent failed with
// "This folder is outside the folders this pane may use."
//
// The pane runs on its in-page mock daemon (transport "mock"), whose `session/new` here refuses the
// home folder as the relay does (AcpmuxPathPolicy, `transport.path_outside_roots`) unless the host
// named it as the start folder (the person answered Use Home Folder).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const HOME = "/Users/you";
const AGENTS = ["claude", "codex", "opencode"] as const;

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;
let restoreAnswer: (() => void) | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const harnesses = AGENTS.map((id) => ({ id, name: id, models: [{ id: `${id}-model`, name: `${id} model` }] }));
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    Element: dom.window.Element,
    Event: dom.window.Event,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
    cmuxAcpmuxMockHarnesses: harnesses,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia, cmuxAcpmuxMockHarnesses: harnesses });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  restoreAnswer?.();
  restoreAnswer = undefined;
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
  await settleReact();
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

const tick = () =>
  act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
async function until(check: () => boolean, what: string, within = 10_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
type Actions = Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
const actions = () => (dom.window as unknown as { cmuxAcpmuxActions?: Actions }).cmuxAcpmuxActions;

/// A New Tab in a fresh workspace: the tab's folder is the home folder, and the host names no start
/// folder (the chat would start in the workspace's private folder), unless `homeAnswered`: the person
/// answered Use Home Folder, so the host names the home folder as the start folder.
/// Records each `session/new`'s folder ("" for none) and each refusal.
async function mountFreshWorkspaceTab(options: { homeAnswered?: boolean } = {}) {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  const starts: { harness: string; cwd: string }[] = [];
  const refused: string[] = [];
  proto.answer = function (this: unknown, method, params) {
    if (method === "session/new") {
      const meta = (params._meta as { acpmux?: { harness?: string } } | undefined)?.acpmux;
      const cwd = typeof params.cwd === "string" ? params.cwd : "";
      starts.push({ harness: meta?.harness ?? "", cwd });
      if (cwd === HOME && !options.homeAnswered) {
        refused.push(cwd);
        return Promise.reject(
          Object.assign(new Error("This folder is outside the folders this pane may use."), {
            code: "transport.path_outside_roots",
            data: { origin: "native" },
          }),
        );
      }
    }
    return answer.call(this, method, params);
  };

  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) =>
            Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "mock",
                      newSession: true,
                      machineName: "Mac",
                      ...(options.homeAnswered ? { cwd: HOME } : { chooseFolder: true }),
                      newTab: { cwd: HOME, home: HOME, projects: [] },
                    }
                  : undefined,
            }),
        },
      },
    },
  });
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(() => actions()?.["chat.new"] !== undefined, "the pane connected to the mock daemon");
  return { starts, refused };
}

test("every agent's new chat with No folder starts without a folder, never in the tab's ~", async () => {
  const { starts, refused } = await mountFreshWorkspaceTab();
  for (const harness of AGENTS) {
    const before = starts.length;
    // What the chips' agent or model pick and the slash command list ask for: the tab's own folder.
    // A deferred start settles only once its chat shows, with the next prompt: not awaited.
    await act(async () => {
      void actions()!["chat.new"]!({ harness, cwd: HOME, deferred: true }).catch(() => undefined);
    });
    await until(() => starts.length > before, `${harness}: a session/new went out`);
    expect(starts.slice(before).map((start) => [start.harness, start.cwd])).toEqual([[harness, ""]]);
  }
  expect(refused).toEqual([]);
});

test("a start the person sends with no folder never reuses an earlier start's folder", async () => {
  const { HarnessSwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  // The harness switch on its own port: an earlier start in a folder that was refused, then the
  // person's next start of each agent, with no folder (the pane's start folder is none).
  const created: { harness: string; cwd?: string }[] = [];
  const store = new HarnessSwitch();
  store.setHandlers({ notice: () => undefined } as never);
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    create: async (harness: string, cwd?: string) => {
      created.push({ harness, ...(cwd ? { cwd } : {}) });
      if (cwd === HOME) throw new Error("This folder is outside the folders this pane may use.");
      return `${harness}-session`;
    },
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as never);
  // Deferred starts settle only once their chat shows: each is waited for at its create.
  void store.switchTo("claude", HOME, { deferred: true });
  await until(() => created.length === 1, "the start in the refused folder ran");
  for (const harness of AGENTS) {
    const before = created.length;
    void store.switchTo(harness, null, { deferred: true });
    await until(() => created.length > before, `${harness}: the next start ran`);
  }
  expect(created).toEqual([{ harness: "claude", cwd: HOME }, ...AGENTS.map((harness) => ({ harness }))]);
});

test("a folder the pane refused is never started again: not by a later pick, not by Retry", async () => {
  const { HarnessSwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const created: { harness: string; cwd?: string }[] = [];
  const store = new HarnessSwitch();
  store.setHandlers({ notice: () => undefined } as never);
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    create: async (harness: string, cwd?: string) => {
      created.push({ harness, ...(cwd ? { cwd } : {}) });
      if (cwd === HOME)
        throw Object.assign(new Error("This folder is outside the folders this pane may use."), {
          code: "transport.path_outside_roots",
        });
      return `${harness}-session`;
    },
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as never);
  // The refused start, then Retry on its "Couldn't start" card.
  void store.switchTo("codex", HOME, { deferred: true });
  await until(() => created.length === 1 && store.view().intent?.phase === "failed", "the start in ~ was refused");
  store.retry();
  await until(() => created.length === 2, "Retry started again");
  // Refused again, then a pick that names no folder (an agent enabled from its card, a seeded agent).
  void store.switchTo("claude", HOME, { deferred: true });
  await until(() => created.length === 3 && store.view().intent?.phase === "failed", "the next start in ~ was refused");
  void store.switchTo("opencode", undefined, { deferred: true });
  await until(() => created.length === 4, "the folderless pick started");
  expect(created).toEqual([
    { harness: "codex", cwd: HOME },
    { harness: "codex" },
    { harness: "claude", cwd: HOME },
    { harness: "opencode" },
  ]);
});

test("after a refused folder, Retry and a send start in the pane's start folder, never the refused one", async () => {
  const { HarnessSwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const created: { harness: string; cwd?: string }[] = [];
  let startFolder: string | undefined = "/work/project";
  const store = new HarnessSwitch();
  store.setHandlers({ notice: () => undefined, restore: () => undefined } as never);
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    create: async (harness: string, cwd?: string) => {
      created.push({ harness, ...(cwd ? { cwd } : {}) });
      if (cwd === HOME || cwd === "/granted/gone")
        throw Object.assign(new Error("This folder is outside the folders this pane may use."), {
          code: "transport.path_outside_roots",
        });
      return `${harness}-session`;
    },
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
    startFolder: () => startFolder,
  } as never);
  const refusedAt = async (count: number, what: string) =>
    until(() => created.length === count && store.view().intent?.phase === "failed", what);
  // Retry goes to the pane's start folder as it is now.
  void store.switchTo("codex", HOME, { deferred: true });
  await refusedAt(1, "the start in ~ was refused");
  store.retry();
  await until(() => created.length === 2, "Retry started again");
  // A send after the failure (Enter instead of Retry) restarts the same way: no start folder, no folder.
  startFolder = undefined;
  void store.switchTo("claude", "/granted/gone", { deferred: true });
  await refusedAt(3, "the start in a folder that left the roots was refused");
  void store.send("hello")?.catch(() => undefined);
  await until(() => created.length === 4, "the send started again");
  expect(created).toEqual([
    { harness: "codex", cwd: HOME },
    { harness: "codex", cwd: "/work/project" },
    { harness: "claude", cwd: "/granted/gone" },
    { harness: "claude" },
  ]);
});

test("a project folder the person picks counts even when the tab sits in it", async () => {
  const { newChatFolder } = await import("../src/agent-session/acpmux/startFolderModel");
  const project = "/Users/you/code/app";
  expect(newChatFolder({ cwd: project, inherited: project, startFolder: `${project}/sub`, fresh: true })).toBe(project);
  // The inherited home folder or agent-home is never a pick: the start folder, else no folder.
  expect(newChatFolder({ cwd: HOME, inherited: HOME, fresh: true })).toBeNull();
  expect(newChatFolder({ cwd: HOME, inherited: HOME, startFolder: project, fresh: true })).toBe(project);
  expect(newChatFolder({ cwd: HOME, inherited: HOME, fresh: false })).toBeUndefined();
  // Once the person answered Use Home Folder, `~` is the start folder and is used.
  expect(newChatFolder({ cwd: HOME, inherited: HOME, startFolder: HOME, fresh: true })).toBe(HOME);
});

test("once the person answered Use Home Folder, a new chat of any agent starts in ~", async () => {
  const { starts, refused } = await mountFreshWorkspaceTab({ homeAnswered: true });
  for (const harness of AGENTS) {
    const before = starts.length;
    await act(async () => {
      void actions()!["chat.new"]!({ harness, cwd: HOME, deferred: true }).catch(() => undefined);
    });
    await until(() => starts.length > before, `${harness}: a session/new went out`);
    expect(starts.slice(before).map((start) => [start.harness, start.cwd])).toEqual([[harness, HOME]]);
  }
  expect(refused).toEqual([]);
});
