// A cancelled New Tab start is no failure: a stale folder reply or Not now on Trust ends the send
// quietly (the page can send again), while a real refusal still says why. Follow-ups to #28543.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;
let restoreAnswer: (() => void) | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
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
    // acpmux lists no agent: the page has none to name, so its Return sends a bare chat.new.
    cmuxAcpmuxMockHarnesses: undefined,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia, cmuxAcpmuxMockHarnesses: undefined });
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
  // The pane marked the page as the mock daemon's (App.tsx): later files see a plain page again.
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

/// One turn of the page's event loop: what is due now runs, and React renders it.
const tick = () =>
  act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
/// Waits for `check` to hold, a turn at a time; fails with `what` if it never does.
async function until(check: () => boolean, what: string, within = 10_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

type Answer = (method: string, params: Record<string, any>) => Promise<any>;
type Native = { method: string; params?: Record<string, unknown> };

/// The minimal New Tab on the in-page mock daemon. `native` answers the host's calls the test
/// scripts (undefined: the default answer); `daemon` the mock daemon's (undefined: the mock's own).
async function mountNewTab(
  native: (message: Native) => Promise<unknown> | undefined,
  daemon: (method: string, params: Record<string, any>, answer: () => Promise<any>) => Promise<any> | undefined,
  projects: string[] = [],
) {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  proto.answer = function (this: unknown, method, params) {
    return daemon(method, params, () => answer.call(this, method, params)) ?? answer.call(this, method, params);
  };
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: Native) =>
            (
              native(message) ??
              Promise.resolve(
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "mock",
                      newSession: true,
                      machineName: "Mac",
                      newTab: {
                        template: "minimal",
                        layout: "b",
                        lastAgent: "claude",
                        cwd: "/tmp/demo-project",
                        ...(projects.length ? { projects: ["/tmp/demo-project", ...projects] } : {}),
                      },
                    }
                  : undefined,
              )
            ).then((value) => ({ ok: true, value })),
        },
      },
    },
  });
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(() => host.querySelector(".nt-field") !== null, "the New Tab field");
  await until(() => !!(dom.window as any).cmuxAcpmuxActions?.["chat.new"], "mock handshake");
  // The New Tab field is the Markdown field (#29659): it types through its handle, and Return goes
  // to its editor.
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  await until(() => !!(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")), "the prompt editor");
  const editor = () => field.querySelector<HTMLElement>("[contenteditable]")!;
  const enter = () =>
    act(async () => editor().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  const draft = () => field.acpmuxMarkdownField?.plainText() ?? "";
  const ask = async (text: string) => {
    await act(async () => field.acpmuxMarkdownField!.writeText(text, text.length, text.length));
    await enter();
  };
  return { field, ask, enter, draft };
}

/// Picks the SSH machine devbox (the mock lists it as a connected peer). The machine chip's main list
/// is This Mac and Cloud; every machine is in Machines… on its right-click menu (#28999).
async function pickRemote() {
  const machine = () => host.querySelector<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button');
  await until(() => machine() !== null, "the machine chip");
  await act(async () =>
    machine()!.dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    ),
  );
  const machinesItem = () =>
    [...dom.window.document.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')].find(
      (candidate) => candidate.textContent === t("composer.machinesList"),
    );
  await until(() => !!machinesItem(), "Machines… on the machine chip's right-click menu");
  await act(async () => machinesItem()!.click());
  await until(
    () => [...dom.window.document.querySelectorAll(".acpmux-menu-label")].some((node) => node.textContent === "devbox"),
    "devbox pick",
  );
  const remote = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-menu-item")].find(
    (node) => node.querySelector(".acpmux-menu-label")?.textContent === "devbox",
  )!;
  await act(async () => remote.click());
}

const alerts = () => [...host.querySelectorAll('[role="alert"]')].map((node) => node.textContent ?? "");

// #28543 review (P2): a New Tab send whose folder request went stale (a newer folder request
// replaced it before the host answered) never settled, so the page stayed "asking" and ignored
// every later Return. The stale reply must use nothing and still end that send.
test("a stale folder reply ends its New Tab send without using its folder, so the next Return sends", async () => {
  const folderA = "/tmp/stale-folder-a";
  const folderB = "/tmp/stale-folder-b";
  const useFolder: string[] = [];
  let holdA: ((value: unknown) => void) | undefined;
  // Picking a folder asks the host too (chooseProject); only the send's own request for A waits.
  let holdNextA = false;
  const starts: Record<string, any>[] = [];
  const { ask } = await mountNewTab(
    (message) => {
      if (message.method === "project.browse") return Promise.resolve({ cwd: folderA });
      if (message.method !== "workspace.useFolder") return undefined;
      const cwd = String(message.params?.cwd);
      useFolder.push(cwd);
      // The New Tab send's first request for folder A waits for the test.
      if (cwd === folderA && holdNextA) {
        holdNextA = false;
        return new Promise((resolve) => (holdA = resolve));
      }
      return Promise.resolve({ status: "ok", cwd });
    },
    (method, params) => {
      if (method === "session/new") starts.push(params);
      return undefined;
    },
  );
  // The person picks project A on the page (Choose folder…): a send there goes through the host first.
  await act(async () => host.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!.click());
  const browse = [...dom.window.document.querySelectorAll<HTMLElement>('[role="option"]')].find(
    (node) => node.textContent === t("composer.chooseFolderMenu"),
  );
  expect(browse, "Choose folder…").toBeDefined();
  await act(async () => {
    browse!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    browse!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, detail: 1 }));
  });
  await until(
    () => host.querySelector('[aria-label="Folder"]')?.textContent === "stale-folder-a",
    "the page names project A",
  );
  holdNextA = true;
  await ask("start in the picked folder");
  await until(() => holdA !== undefined, "the New Tab send waits on the host's reply for A");
  // A newer folder request (project B, from the pane's own picker) replaces it before the host answers A.
  await act(async () => void (dom.window as any).cmuxAcpmuxDebug.pickFolder(folderB));
  await until(() => useFolder.includes(folderB), "the pick of B went through the host");
  await tick();
  // The host's late reply for A is stale: A is not used for that send.
  await act(async () => holdA!({ status: "ok", cwd: folderA }));
  await tick();
  await tick();
  expect(starts.filter((start) => start.cwd === folderA)).toEqual([]);
  // Cancelled, not failed: nothing says it failed.
  expect(alerts()).toEqual([]);
  // The page is not stuck asking: Return sends again, through the host, and starts in A.
  const asked = useFolder.length;
  await ask("start in the picked folder");
  await until(() => useFolder.length > asked, "the next Return asks the host again");
  expect(useFolder.at(-1)).toBe(folderA);
  await until(() => starts.some((start) => start.cwd === folderA), "the next send starts its chat in A");
  expect(starts.filter((start) => start.cwd === folderA)).toHaveLength(1);
}, 20_000);

// #28543 review (P2): a cancelled New Tab start (Not now on the folder's Trust question, or the
// start aborted because the page moved on) showed a failure notice beside the field. A cancel is
// no failure: no notice, the draft stays, and Return can start it again. A local start becomes its
// chat at once (#28965), so this drives a start on another machine, which keeps the page. A real
// refusal still says why (new-tab-start-refusal.test.tsx).
test("Not now on a New Tab start's Trust question shows no failure notice and keeps the draft", async () => {
  let trusted = false;
  const starts: Record<string, any>[] = [];
  const { field, ask, enter, draft } = await mountNewTab(
    () => undefined,
    (method, params, answer) => {
      if (method === "_acpmux/status")
        return answer().then((result) => ({ ...result, peers: [{ name: "devbox", kind: "ssh", connected: true }] }));
      if (method === "acp.trust.set") trusted = params.level === "trusted";
      if (method !== "session/new") return undefined;
      starts.push(params);
      if (trusted) return answer();
      return Promise.reject(
        Object.assign(new Error("Trust this folder first"), {
          data: { reason: "trust.pending", cwd: "/tmp/start-cancel-trust" },
        }),
      );
    },
  );
  // A start on another machine keeps the page until it has started, so its Trust question and any
  // notice show beside the field.
  await pickRemote();
  await ask("inspect the cancelled start");
  await until(() => !!host.querySelector(".acpmux-trust-ask-primary"), "the Trust question");
  const notNow = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-trust-ask button")].find(
    (button) => button.textContent === t("trust.notNow"),
  )!;
  await act(async () => notNow.click());
  await until(
    () =>
      [...host.querySelectorAll<HTMLButtonElement>(".acpmux-trust-ask-action")].some(
        (button) => button.textContent === t("trust.undo"),
      ),
    "Not now settles and offers Undo",
  );
  await tick();
  await tick();
  expect(alerts().filter((text) => text.includes(t("switch.cancelled")))).toEqual([]);
  expect(host.querySelector('.acpmux-switch-notice[role="alert"]')).toBeNull();
  expect(host.querySelector(".nt-field")).toBe(field);
  expect(draft()).toBe("inspect the cancelled start");
  // The cancelled start settled: Return starts it again.
  await enter();
  await until(() => starts.length === 2, "Return starts the chat again");
}, 20_000);

/// The prompt is still on the page: its queued row in the chat, or the chat's composer.
const kept = (prompt: string) =>
  !!host.textContent?.includes(prompt) ||
  [...host.querySelectorAll("textarea")].some((node) => node.value.includes(prompt));

// A real start failure still says why (the notice is suppressed only for a cancel).
test("a refused New Tab start still shows its failure notice", async () => {
  const { ask } = await mountNewTab(
    () => undefined,
    (method) =>
      method === "session/new" ? Promise.reject(new Error("devbox refused session/new: agent unavailable")) : undefined,
  );
  // A named local harness: the start becomes its chat at once (#28965), which says why it failed.
  await ask("inspect the failed build");
  await until(() => !!host.textContent?.includes("agent unavailable"), "the refusal says why");
  expect(kept("inspect the failed build")).toBe(true);
}, 20_000);
