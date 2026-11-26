// A chat page asks the app for Cloud's last pick (`newTab.cloudPick`), and an unstarted chat already on Cloud takes it
// when the answer comes. The answer, and the grant of a remembered folder of this Mac, are defaults: a folder chosen
// while either was out wins (Greptile on https://github.com/manaflow-ai/cmux/pull/56264 and
// https://github.com/manaflow-ai/cmux/pull/55182, cmux#53226). Before, a late answer replaced No folder (it clears
// the draft and the pick both), dropped a local pick the host had not answered yet, and a grant still out replaced a
// GitHub repository picked after it.
//
// The pane runs its real client against the in-page mock daemon; the native host is a stub.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

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
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia });
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = dom.window.document.getElementById("root")!;
});

type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let restoreAnswer: (() => void) | undefined;
/// The daemon methods the page sent, in order.
let daemonCalls: string[] = [];

const FOLDER = "/tmp/cloud-empty-chat";
const PROMPT = "Run the sidebar tests and fix what fails";

/// The project folder is trusted on the mock daemon, and every method it gets is recorded.
async function trustFolder() {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  proto.answer = function (this: unknown, method, params) {
    daemonCalls.push(method);
    if (method === "acp.trust.get" && params.cwd === FOLDER)
      return Promise.resolve({ cwd: FOLDER, level: "trusted", harnesses: { claude: "trusted", codex: "trusted" } });
    return answer.call(this, method, params);
  };
}

afterEach(async () => {
  // A new launch: the page asks the app again.
  (await import("../src/agent-session/acpmux/newtab/startedProject")).forgetAppCloudPickForTests();
  restoreAnswer?.();
  restoreAnswer = undefined;
  daemonCalls = [];
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
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
async function until(check: () => boolean, what: string, within = 15_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

type FieldElement = HTMLElement & { acpmuxMarkdownField?: { value(): string; type(text: string): unknown } };
const promptElement = () => host.querySelector<FieldElement>(".acpmux-composer-prompt");
const promptField = () => {
  const element = promptElement();
  return element?.querySelector("[contenteditable]") ? element.acpmuxMarkdownField : undefined;
};

type Debug = {
  runMode(mode?: string): { runMode?: string | null; error?: string };
  pickFolder(cwd: string): Record<string, unknown>;
};
const debug = () => (dom.window as unknown as { cmuxAcpmuxDebug?: Debug }).cmuxAcpmuxDebug!;
const actions = () => (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions;

const PICKED = "/Users/you/src/app";
const REMEMBERED = "/Users/you/src/old";

/// A new chat whose host offers Cloud. `newTab.cloudPick` answers `remembered` only when `answerCloudPick()` runs;
/// `workspace.useFolder` answers each folder only when `grant()` runs.
async function mount(remembered: string, { cloud = true }: { cloud?: boolean } = {}) {
  if (!restoreAnswer) await trustFolder();
  const starts: Record<string, unknown>[] = [];
  const grants: (() => void)[] = [];
  const cloudPicks: (() => void)[] = [];
  const asked: string[] = [];
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) => {
            if (message.method === "cloud.startChat") {
              starts.push({ ...message.params });
              return new Promise(() => {});
            }
            if (message.method === "newTab.cloudPick")
              return new Promise((done) =>
                cloudPicks.push(() => done({ ok: true, value: { cloudStarted: remembered } })),
              );
            // GitHub is connected and lists one repository, for the folder menu's GitHub part.
            if (message.method === "github.status")
              return Promise.resolve({ ok: true, value: { state: "ready", repos_scope: "all" } });
            if (message.method === "github.repos.list")
              return Promise.resolve({
                ok: true,
                value: { repos: [{ full_name: "acme/web", private: false, default_branch: "main" }], truncated: false },
              });
            if (message.method === "workspace.useFolder") {
              const cwd = message.params?.cwd;
              asked.push(String(cwd));
              return new Promise((done) => grants.push(() => done({ ok: true, value: { status: "ok", cwd } })));
            }
            return Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "mock",
                      newSession: true,
                      machineName: "Mac",
                      sandboxState: true,
                      cwd: FOLDER,
                    }
                  : message.method === "sandbox.state"
                    ? {}
                    : message.method === "transport.gesture"
                      ? { ticket: "ticket-1" }
                      : undefined,
            });
          },
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(() => actions() !== undefined && promptField() !== undefined, "the new chat connects");
  await until(() => cloudPicks.length === 1, "the chat page asks the app for Cloud's last pick");
  if (cloud) await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is picked");
  return {
    starts,
    asked,
    grant: () => act(async () => grants.splice(0).forEach((run) => run())),
    answerCloudPick: async () => {
      await act(async () => cloudPicks.splice(0).forEach((run) => run()));
      for (let step = 0; step < 5; step += 1) await tick();
    },
  };
}

async function pressSend() {
  const editable = promptElement()!.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editable.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  await tick();
}

/// Types the prompt and presses Return until the Cloud start goes out; its `cwd`.
async function sendAndReadFolder(pane: { starts: Record<string, unknown>[] }) {
  await act(async () => void promptField()!.type(PROMPT));
  await until(() => promptField()?.value() === PROMPT, "the composer takes the prompt");
  await pressSend();
  await until(() => pane.starts.length === 1, "the send starts the chat in Cloud");
  return pane.starts[0]!.cwd;
}

const folderChip = () =>
  host.querySelector<HTMLButtonElement>(`.acpmux-composer-context button[aria-label="${t("composer.folder")}"]`);

const option = (which: (option: HTMLElement) => boolean) =>
  [...dom.window.document.querySelectorAll<HTMLElement>("[role=option], [role=menuitem]")].find(which);
async function click(which: (option: HTMLElement) => boolean, what: string) {
  await until(() => option(which) !== undefined, what);
  await act(async () => option(which)!.click());
}

/// The folder menu's row `which` names, clicked as the person does.
async function chooseFromFolderMenu(which: (option: HTMLElement) => boolean, what: string) {
  await act(async () => folderChip()!.click());
  await click(which, what);
}

async function chooseNoFolder() {
  await chooseFromFolderMenu((option) => option.querySelector("[data-no-folder]") !== null, "the menu lists No folder");
  await until(() => folderChip()?.textContent?.includes(t("project.noFolder")) === true, "the chip reads No folder");
}

test("No folder chosen before the app's Cloud pick answers stays No folder", async () => {
  const pane = await mount("github:acme/api");
  await chooseNoFolder();
  await pane.answerCloudPick();
  // Before: the chip read acme/api and the Cloud start cloned it.
  expect(folderChip()?.textContent).toContain(t("project.noFolder"));
  expect(await sendAndReadFolder(pane)).not.toBe("github:acme/api");
}, 60_000);

test("a folder of this Mac picked before the app's Cloud pick answers is the one the Cloud chat starts in", async () => {
  const pane = await mount(REMEMBERED);
  await act(async () => void debug().pickFolder(PICKED));
  await until(() => pane.asked.includes(PICKED), "the pick asks the host for the folder");
  await pane.answerCloudPick();
  // Before: the answer asked for the remembered folder too, which dropped the pick still out.
  expect(pane.asked).toEqual([PICKED]);
  await pane.grant();
  expect(await sendAndReadFolder(pane)).toBe(PICKED);
}, 60_000);

test("a GitHub repository picked while the remembered folder's grant is out is the one the Cloud chat starts in", async () => {
  const pane = await mount(REMEMBERED);
  await pane.answerCloudPick();
  await until(() => pane.asked.includes(REMEMBERED), "Cloud asks the host for its remembered folder");
  // Add project…, then GitHub repository, lists the repositories.
  await chooseFromFolderMenu((row) => row.textContent === t("project.add"), "the menu has Add project…");
  await click((row) => row.textContent?.startsWith(t("project.github")) === true, "Add project… offers GitHub");
  await click((row) => row.textContent?.includes("acme/web") === true, "Add project… lists acme/web");
  await until(() => folderChip()?.textContent?.includes("acme/web") === true, "the chip reads acme/web");
  // Before: the grant answered after the pick and put the remembered folder back.
  await pane.grant();
  for (let step = 0; step < 5; step += 1) await tick();
  expect(await sendAndReadFolder(pane)).toBe("github:acme/web");
}, 60_000);

test("a choice made on This Mac before Cloud was picked does not hold off Cloud's late default", async () => {
  const pane = await mount("github:acme/api", { cloud: false });
  await chooseNoFolder();
  // Cloud from the Where menu, as the person picks it.
  const where = () =>
    host.querySelector<HTMLButtonElement>(
      `.acpmux-composer-context button[aria-label^="${t("composer.environment")}"]`,
    );
  await until(() => where() !== null, "the composer has its Where control");
  await act(async () => where()!.click());
  await click((row) => row.textContent?.startsWith(t("composer.cloud")) === true, "the Where menu offers Cloud");
  await until(() => debug().runMode().runMode === "cloud", "Cloud is picked");
  await pane.answerCloudPick();
  // Cloud's default replaced This Mac's No folder when Cloud was picked; its late answer is still Cloud's default.
  await until(() => folderChip()?.textContent?.includes("acme/api") === true, "the chip reads Cloud's last pick");
}, 60_000);
