// l10n-allow-file: test fixture reasons, workspace and tab titles, not shipped UI.
// Needs you's marked tabs (tab-attention-v1, Leo 2026-10-22: "idk where things are man i dont see
// anything other than the current workspace"): a tab an agent marked with `cmux attention request`
// is one `tab` item, read from the host's push, that says what to do there and where (the
// workspace and tab by their titles, never an id); its Go to asks the host to show that tab, and
// it offers no answers and no side question, since it names no chat.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../src/agent-session/acpmux/i18n";
import {
  ATTENTION_OPEN_OP,
  attentionTabs,
  parseAttentionTabs,
  setAttentionTabs,
} from "../src/agent-session/acpmux/needsYou/attentionTabs";
import { needsYouItems, type NeedsYouItem } from "../src/agent-session/acpmux/needsYou/model";
import { NeedsYouPanel, type NeedsYouActions } from "../src/agent-session/acpmux/needsYou/NeedsYou";
import { useNeedsYou } from "../src/agent-session/acpmux/needsYou/useNeedsYou";

const pushed = [
  {
    kind: "tab",
    tabId: "tab_login",
    reason: "Log in to GitHub",
    workspaceTitle: "cmux next",
    tabTitle: "GitHub",
    atMs: 1_000,
  },
  {
    kind: "tab",
    tabId: "tab_deploy",
    reason: "Approve the deploy",
    workspaceTitle: "Release",
    tabTitle: "Vercel",
    atMs: 3_000,
  },
];

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  setAttentionTabs([]);
});

test("the host's push keeps each well-formed marked tab, newest first, and drops the rest", () => {
  expect(
    parseAttentionTabs([
      ...pushed,
      { kind: "chat", tabId: "tab_x", reason: "x" },
      { kind: "tab", tabId: "", reason: "no id" },
      { kind: "tab", tabId: "tab_y", reason: "   " },
      { kind: "tab", tabId: "tab_no_time", reason: "no at_ms" },
      { kind: "tab", tabId: "tab_text_time", reason: "x", atMs: "1000" },
      { kind: "tab", tabId: "tab_negative", reason: "x", atMs: -1 },
      { kind: "tab", tabId: "tab_fraction", reason: "x", atMs: 1.5 },
      { kind: "tab", tabId: "tab_nan", reason: "x", atMs: Number.NaN },
      "tab_z",
      null,
    ]).map((tab) => tab.tabId),
  ).toEqual(["tab_deploy", "tab_login"]);
  expect(parseAttentionTabs(null)).toEqual([]);
  setAttentionTabs(pushed);
  expect(attentionTabs()).toHaveLength(2);
  setAttentionTabs("garbage");
  expect(attentionTabs()).toEqual([]);
});

test("a marked tab is one tab item: the reason, its workspace and title, no answers", () => {
  const items = needsYouItems({ sessions: [], asks: [], tabs: parseAttentionTabs(pushed) });
  expect(items.map((item) => item.id)).toEqual(["tab:tab_deploy", "tab:tab_login"]);
  expect(items[1]).toEqual({
    id: "tab:tab_login",
    kind: "tab",
    sessionId: "",
    ask: "Log in to GitHub",
    detail: "GitHub",
    who: { name: "cmux next", chief: false },
    at: 1_000,
    answers: [],
    tabId: "tab_login",
  });
});

test("the panel lists a marked tab by its titles, never its id, with Go to and no side question", async () => {
  const host = installDom();
  const items = needsYouItems({ sessions: [], asks: [], tabs: parseAttentionTabs(pushed.slice(0, 1)) });
  const went: string[] = [];
  const actions: NeedsYouActions = {
    answer: async () => undefined,
    goTo: (item) => void went.push(item.id),
    ask: async () => "",
  };
  root = createRoot(host);
  await act(async () => root!.render(<NeedsYouPanel items={items} actions={actions} />));
  const row = host.querySelector(".acpmux-needs-you-item")!;
  expect(row.getAttribute("data-kind")).toBe("tab");
  expect(row.textContent).toContain("Log in to GitHub");
  expect(row.textContent).toContain("cmux next");
  expect(row.textContent).toContain("GitHub");
  expect(row.textContent).toContain(translate("needsYou.kind.tab"));
  expect(row.textContent).not.toContain("tab_login");
  expect(row.querySelector(".acpmux-needs-you-ask-about")).toBeNull();
  expect(row.querySelector(".acpmux-needs-you-answer")).toBeNull();
  await act(async () => {
    row.querySelector(".acpmux-needs-you-go")!.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
  expect(went).toEqual(["tab:tab_login"]);
});

test("Go to on a marked tab asks the host to show that tab and nothing else", async () => {
  const host = installDom();
  setAttentionTabs(pushed);
  const calls: string[] = [];
  const callNative = (async (method: string, params?: Record<string, unknown>) => {
    calls.push(`${method}:${String(params?.tabId ?? params?.sessionId ?? "")}`);
    return undefined;
  }) as <T>(method: string, params?: Record<string, unknown>) => Promise<T>;
  let actions: NeedsYouActions | undefined;
  let items: NeedsYouItem[] = [];
  function Probe() {
    const needsYou = useNeedsYou({
      snapshot: { sessionId: "here", rows: [], sessions: [], asks: [] },
      callNative,
      sideSession: async (sessionId) => void calls.push(`btw:${sessionId}`),
    });
    actions = needsYou.actions;
    items = needsYou.items;
    return null;
  }
  root = createRoot(host);
  await act(async () => root!.render(<Probe />));
  expect(items.map((item) => item.kind)).toEqual(["tab", "tab"]);
  const login = items.find((item) => item.tabId === "tab_login")!;
  actions!.goTo(login);
  await Promise.resolve();
  expect(calls).toEqual([`${ATTENTION_OPEN_OP}:tab_login`]);
  await expect(actions!.ask(login, "Why?")).rejects.toThrow();
  expect(calls).toEqual([`${ATTENTION_OPEN_OP}:tab_login`]);
  // A cleared mark leaves the list on the next push.
  await act(async () => setAttentionTabs(pushed.slice(1)));
  expect(items.map((item) => item.tabId)).toEqual(["tab_deploy"]);
});
