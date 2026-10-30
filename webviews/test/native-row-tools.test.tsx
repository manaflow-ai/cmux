// l10n-allow-file: native toolbar descriptors and synthetic test labels, not shipped UI.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { HEADER_ACTIONS } from "../src/agent-session/acpmux/header/headerActions";
import { headerQuickTools, type HeaderQuickToolsInput } from "../src/agent-session/acpmux/header/headerQuickTools";
import { headerState, setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import {
  dispatchNativeRowTool,
  nativeRowToolBindings,
  boundedNativeText,
  NATIVE_MAX_TOTAL_MENU_ITEMS,
  NATIVE_MAX_TEXT_BYTES,
  NATIVE_MAX_TEXT_GRAPHEMES,
  type NativeRowExtras,
  type NativeRowTool,
} from "../src/agent-session/acpmux/header/nativeRowTools";
import { configureQuickActions, quickActions } from "../src/agent-session/acpmux/header/quickActions";
import { setTabRow, useTabRow, type TabRow } from "../src/agent-session/acpmux/header/tabRow";
import { useNativeRowTools } from "../src/agent-session/acpmux/header/useNativeRowTools";
import { NeedsYouButton } from "../src/agent-session/acpmux/needsYou/NeedsYou";
import { applyHostEvent } from "../src/agent-session/acpmux/pageHost";
import { translate } from "../src/agent-session/acpmux/i18n";
import { openPicker } from "../src/agent-session/acpmux/pickerOpeners";
import { SummaryButton } from "../src/agent-session/acpmux/summary/SummaryButton";

const ids = ["newTab", "changes", "files", "preview", "splitDown", "terminal", "browser"] as const;
function quickInput(calls: string[]): HeaderQuickToolsInput {
  return {
    actions: ids.map((id) => ({ id, mode: "toggle" })),
    tabTools: true,
    sideTabs: true,
    lit: [HEADER_ACTIONS.changes, HEADER_ACTIONS.files, HEADER_ACTIONS.terminal],
    browserOpensPreview: true,
    hasChanges: true,
    previewUrl: "http://localhost:5173/",
    onTerminal: (mode) => void calls.push(`terminal:${mode}`),
    onBrowser: (mode) => void calls.push(`browser:${mode}`),
    onSplitDown: (mode) => void calls.push(`splitDown:${mode}`),
    onChanges: (mode) => void calls.push(`changes:${mode}`),
    onFiles: (mode) => void calls.push(`files:${mode}`),
    onPreview: (url, mode) => void calls.push(`preview:${mode}:${url}`),
    onSideTabs: () => void calls.push("newTab"),
    t: (key) => key,
  };
}

test("native descriptors preserve quick-action order, toolbar symbols, state and panel semantics", () => {
  const input = quickInput([]);
  const bindings = nativeRowToolBindings(headerQuickTools(input), {
    id: "summary",
    label: "Chat summary",
    toggled: true,
    run: () => {},
  });
  expect(bindings.map(({ tool }) => tool.id)).toEqual(["summary", ...ids]);
  expect(bindings.map(({ tool }) => tool.symbol)).toEqual([
    "list.bullet",
    "sidebar.right",
    "plusminus",
    "folder",
    "play",
    "rectangle.split.1x2",
    "terminal",
    "globe",
  ]);
  expect(bindings.map(({ tool }) => tool.toggled)).toEqual([true, true, true, true, false, false, true, false]);
  expect(bindings.every(({ tool }) => tool.enabled)).toBe(true);
  expect(bindings[0]!.tool).not.toHaveProperty("badge");
  expect(bindings.some(({ tool }) => tool.id === "needsYou")).toBe(false);
  const disabled = nativeRowToolBindings(headerQuickTools({ ...input, onSideTabs: undefined }), {
    id: "inspector",
    label: "Session Info",
    toggled: false,
  });
  expect(disabled[0]!.tool).toMatchObject({ id: "inspector", enabled: false, toggled: false });
  expect(disabled[1]!.tool.enabled).toBe(false);
  const open = nativeRowToolBindings(headerQuickTools({ ...input, actions: [{ id: "terminal", mode: "open" }] }));
  expect(open[0]!.tool.toggled).toBe(false);
  expect(nativeRowToolBindings(headerQuickTools({ ...input, sideTabs: false }))[0]!.tool.symbol).toBe("plus");
});

test("every native id dispatches the shared handler; invalid, disabled and menu invocations do nothing", () => {
  const calls: string[] = [];
  const bindings = nativeRowToolBindings(headerQuickTools(quickInput(calls)), {
    id: "summary",
    label: "Summary",
    toggled: false,
    run: () => void calls.push("summary"),
  });
  for (const { tool } of bindings) dispatchNativeRowTool({ id: tool.id }, bindings);
  expect(calls).toEqual([
    "summary",
    "newTab",
    "changes:toggle",
    "files:toggle",
    "preview:toggle:http://localhost:5173/",
    "splitDown:toggle",
    "terminal:toggle",
    "browser:toggle",
  ]);
  const disabled = [{ tool: { ...bindings[0]!.tool, enabled: false }, run: () => void calls.push("disabled") }];
  dispatchNativeRowTool({ id: "summary" }, disabled);
  for (const value of [
    null,
    undefined,
    true,
    "terminal",
    {},
    { id: 7 },
    { id: "missing" },
    { id: "terminal", menuItemId: "x" },
    { id: "terminal", menuItemId: null },
  ])
    dispatchNativeRowTool(value, bindings);
  expect(calls).toHaveLength(8);
  dispatchNativeRowTool(
    { id: "inspector" },
    nativeRowToolBindings([], {
      id: "inspector",
      label: "Session Info",
      toggled: true,
      run: () => void calls.push("inspector"),
    }),
  );
  expect(calls.at(-1)).toBe("inspector");
});

test("native bindings describe worktree, pull request and Needs You menus", async () => {
  const calls: string[] = [];
  const item = {
    id: "acpmux:permission-1",
    kind: "approval" as const,
    sessionId: "chat-1",
    ask: "Allow the deploy command?",
    who: { name: "Claude", chief: false },
    answers: [{ id: "allow", label: "Allow once", tone: "allow" as const }],
    permissionId: "permission-1",
  };
  const extras: NativeRowExtras = {
    worktree: {
      value: { branch: "fix/login", base: "main", mainRoot: "/repo" },
      onApply: async (key) => void calls.push(`apply:${key.length > 0}`),
      onRemove: async (_key, discard) => void calls.push(`remove:${discard}`),
    },
    pullRequest: {
      value: {
        url: "https://github.com/manaflow-ai/cmux/pull/42",
        number: 42,
        title: "Fix login",
        state: "open",
        review: "approved",
        mergeable: "mergeable",
        checks: { state: "passing", passed: 2, total: 2 },
        checkList: [],
      },
      onMerge: async ({ number }) => {
        calls.push(`merge:${number}`);
        return { queued: false };
      },
    },
    needsYou: {
      items: [item],
      mode: "pinned",
      actions: {
        answer: async (_item, choice) => void calls.push(`answer:${choice.id}`),
        goTo: (value) => void calls.push(`go:${value.id}`),
        ask: async (value) => void calls.push(`ask:${value.id}`),
      },
    },
  };
  const bindings = nativeRowToolBindings([], undefined, extras);
  expect(bindings.map(({ tool }) => tool.id)).toEqual(["worktree", "pullRequest", "needsYou"]);
  const worktreeMenu = bindings[0]!.tool.menu ?? [];
  expect(worktreeMenu).toHaveLength(2);
  expect(worktreeMenu[0]!.id).toMatch(/^worktree\.apply:/);
  expect(worktreeMenu[1]!.id).toMatch(/^worktree\.remove:/);
  expect(bindings[1]!.tool).toMatchObject({ badge: "#42 ✓2/2", toggled: true });
  expect(bindings[1]!.tool.menu).toEqual([
    { id: expect.stringMatching(/^pullRequest\.open:/), label: "Open pull request", enabled: true },
    { id: expect.stringMatching(/^pullRequest\.merge:/), label: "Merge", enabled: true },
  ]);
  expect(bindings[2]!.tool.badge).toBe("1");
  const needsChildren = bindings[2]!.tool.menu?.[0]?.children ?? [];
  expect(needsChildren).toHaveLength(3);
  expect(needsChildren.every(({ id }) => id.length <= 64)).toBe(true);

  dispatchNativeRowTool({ id: "worktree", menuItemId: worktreeMenu[0]!.id }, bindings);
  dispatchNativeRowTool({ id: "worktree", menuItemId: worktreeMenu[1]!.id }, bindings);
  const mergeMenuId = bindings[1]!.tool.menu?.find((item) => item.id.startsWith("pullRequest.merge:"))?.id;
  dispatchNativeRowTool({ id: "pullRequest", menuItemId: mergeMenuId }, bindings);
  const confirmed = nativeRowToolBindings([], undefined, {
    pullRequest: { ...extras.pullRequest!, mergeState: { step: "confirm" } },
  });
  dispatchNativeRowTool(
    {
      id: "pullRequest",
      menuItemId: confirmed[0]!.tool.menu?.find((item) => item.id.startsWith("pullRequest.merge:"))?.id,
    },
    confirmed,
  );
  for (const child of needsChildren) dispatchNativeRowTool({ id: "needsYou", menuItemId: child.id }, bindings);
  await Promise.resolve();
  expect(calls).toContain("remove:false");
  expect(calls).toContain("merge:42");
  expect(calls).toContain("answer:allow");
  expect(calls).toContain("go:acpmux:permission-1");
  expect(calls).toContain("ask:acpmux:permission-1");
});

test("conditional quick actions and Browser's preview delegation keep the web behavior", () => {
  const calls: string[] = [];
  const input = quickInput(calls);
  expect(headerQuickTools({ ...input, tabTools: false })).toEqual([]);
  expect(
    headerQuickTools({
      ...input,
      hasChanges: false,
      previewUrl: undefined,
      lit: [],
      onFiles: undefined,
      onSplitDown: undefined,
    }).map(({ id }) => id),
  ).toEqual(["newTab", "terminal", "browser"]);
  const browser = headerQuickTools({
    ...input,
    actions: [{ id: "browser", mode: "toggle" }],
    lit: [HEADER_ACTIONS.preview],
  });
  expect(nativeRowToolBindings(browser)[0]!.tool.toggled).toBe(true);
  dispatchNativeRowTool({ id: "browser" }, nativeRowToolBindings(browser));
  expect(calls).toEqual(["preview:toggle:http://localhost:5173/"]);
});

test("native descriptors honor decoder text and aggregate menu budgets", () => {
  const emoji = "👨‍👩‍👧‍👦".repeat(64);
  const longNeeds = Array.from({ length: 32 }, (_, index) => ({
    id: `needs-${index}`,
    kind: "approval" as const,
    sessionId: "chat",
    ask: index === 0 ? "" : emoji,
    who: { name: "A", chief: false },
    answers: Array.from({ length: 5 }, (_, answer) => ({
      id: `answer-${answer}`,
      label: answer ? emoji : "",
      tone: "allow" as const,
    })),
    permissionId: `permission-${index}`,
  }));
  const checks = Array.from({ length: 31 }, (_, index) => ({
    name: `check-${index}`,
    state: index % 2 ? "pending" : "failed",
    url: index === 0 ? undefined : `https://example.test/${index}`,
  }));
  const bindings = nativeRowToolBindings([], undefined, {
    worktree: {
      value: { branch: "feature/long-branch-name", base: "main", mainRoot: "/repo" },
      onApply: async () => {},
    },
    pullRequest: {
      value: {
        url: "https://example.test/pr/42",
        number: 42,
        title: "PR",
        state: "open",
        review: "approved",
        mergeable: "conflicting",
        checks: { state: "failing", passed: 0, total: checks.length },
        checkList: checks,
      },
    },
    needsYou: {
      mode: "pinned",
      items: longNeeds,
      actions: { answer: async () => {}, ask: async () => {}, goTo: () => {} },
    },
  });
  const count = (items: readonly { children?: readonly any[] }[]): number =>
    items.reduce((total, item) => total + 1 + (item.children ? count(item.children) : 0), 0);
  expect(
    bindings.flatMap(({ tool }) => tool.menu ?? []).reduce((total, item) => total + count([item]), 0),
  ).toBeLessThanOrEqual(NATIVE_MAX_TOTAL_MENU_ITEMS);
  for (const { tool } of bindings) {
    expect(tool.label.length).toBeGreaterThan(0);
    expect(new TextEncoder().encode(tool.label).byteLength).toBeLessThanOrEqual(NATIVE_MAX_TEXT_BYTES);
    for (const item of tool.menu ?? []) expect(item.label.length).toBeGreaterThan(0);
  }
  const worktree = bindings.find(({ tool }) => tool.id === "worktree")!.tool;
  expect(worktree.badge).toContain("feature/");
  expect(worktree.badge).toContain("branch-name");
  expect(
    Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(boundedNativeText(emoji))).length,
  ).toBeLessThanOrEqual(NATIVE_MAX_TEXT_GRAPHEMES);
  expect(boundedNativeText("")).toBe("…");
  expect(bindings.find(({ tool }) => tool.id === "pullRequest")!.tool.menu).toEqual(
    expect.arrayContaining([expect.objectContaining({ enabled: false })]),
  );
});

test("native menu ids reject stale worktree, pull request and Needs You selections", () => {
  const calls: string[] = [];
  const item = (id: string) => ({
    id,
    kind: "approval" as const,
    sessionId: "chat",
    ask: "Approve",
    who: { name: "A", chief: false },
    answers: [{ id: "yes", label: "Yes", tone: "allow" as const }],
    permissionId: id,
  });
  const old = nativeRowToolBindings([], undefined, {
    worktree: {
      value: { branch: "old", base: "main", mainRoot: "/repo" },
      onApply: async () => calls.push("old-worktree"),
    },
    pullRequest: {
      value: {
        url: "https://example.test/old",
        number: 1,
        title: "old",
        state: "open",
        review: "approved",
        mergeable: "conflicting",
        checks: { state: "none", passed: 0, total: 0 },
        checkList: [],
      },
      onMerge: async () => ({ queued: false }),
    },
    needsYou: {
      mode: "pinned",
      items: [item("old")],
      actions: { answer: async () => calls.push("old-needs"), ask: async () => {}, goTo: () => {} },
    },
  });
  const current = nativeRowToolBindings([], undefined, {
    worktree: {
      value: { branch: "new", base: "main", mainRoot: "/repo" },
      onApply: async () => calls.push("new-worktree"),
    },
    pullRequest: {
      value: {
        url: "https://example.test/new",
        number: 2,
        title: "new",
        state: "open",
        review: "approved",
        mergeable: "conflicting",
        checks: { state: "none", passed: 0, total: 0 },
        checkList: [],
      },
      onMerge: async () => ({ queued: false }),
    },
    needsYou: {
      mode: "pinned",
      items: [item("new")],
      actions: { answer: async () => calls.push("new-needs"), ask: async () => {}, goTo: () => {} },
    },
  });
  for (const index of [0, 1, 2]) {
    const oldMenu = old[index]!.tool.menu?.[0];
    if (oldMenu) dispatchNativeRowTool({ id: old[index]!.tool.id, menuItemId: oldMenu.id }, current);
  }
  expect(calls).toEqual([]);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let previousHeader: ReturnType<typeof headerState> | undefined;
let previousQuick: ReturnType<typeof quickActions> | undefined;
let previousTabRow: TabRow | undefined;
function mount() {
  previousHeader = headerState();
  previousQuick = quickActions();
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  configureQuickActions({ quickActions: ["terminal", "browser"] });
  setHeaderState({ lit: [], pullRequest: null, browserOpensPreview: true });
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  if (previousQuick) configureQuickActions({ quickActions: previousQuick });
  if (previousHeader) setHeaderState({ ...previousHeader, pullRequest: previousHeader.pullRequest ?? null });
  previousQuick = undefined;
  if (previousTabRow) setTabRow(previousTabRow);
  previousTabRow = undefined;
  previousHeader = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, { had, value }] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  saved.clear();
});

test("host events switch the header to native tools and invoke the same web handlers", async () => {
  const container = mount();
  const sent: { method: string; tools: NativeRowTool[] }[] = [];
  const called: string[] = [];
  const callNative = async (method: string, params: Record<string, unknown>) => {
    sent.push({ method, tools: params.tools as NativeRowTool[] });
  };
  function Header({ generation }: { generation: string }) {
    const row = useTabRow();
    previousTabRow ??= row;
    const panel = () => void called.push(`summary:${generation}`);
    return (
      <ChatHeaderTools
        onTerminal={() => void called.push(`terminal:${generation}`)}
        onBrowser={() => void called.push(`browser:${generation}`)}
        summary={(native) => (
          <SummaryButton
            native={native}
            card={{
              shown: false,
              column: false,
              reserve: false,
              collapsed: false,
              toggle: panel,
              show: panel,
              close: panel,
              fold: () => {},
            }}
          />
        )}
        inbox={
          <NeedsYouButton
            items={[]}
            actions={{
              answer: async () => {},
              ask: async () => {},
              goTo: () => {},
            }}
          />
        }
        nativeNeedsYou={{
          mode: "pinned",
          items: [
            {
              id: "needs-1",
              kind: "approval",
              sessionId: "chat-1",
              ask: "Approve",
              who: { name: "A", chief: false },
              answers: [{ id: "allow", label: "Allow", tone: "allow" }],
              permissionId: "p-1",
            },
          ],
          actions: { answer: async () => {}, ask: async () => {}, goTo: () => {} },
        }}
        menu={() => [
          {
            key: "rename",
            label: "Rename",
            icon: "action.edit",
            onSelect: () => {},
          },
        ]}
        nativeRowTools={{
          enabled: row.height > 0 && row.nativeRowTools === true,
          callNative,
          panel: {
            id: "summary",
            label: "Chat summary",
            toggled: false,
            run: panel,
          },
        }}
      />
    );
  }
  const render = async (enabled: boolean, generation: string) => {
    await act(async () => root!.render(<Header generation={generation} />));
    await act(async () =>
      applyHostEvent({
        kind: "tabRow",
        value: { height: 28, nativeRowTools: enabled },
      }),
    );
  };
  await render(false, "off");
  expect(sent).toHaveLength(0);
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(2);
  expect(container.querySelector(".acpmux-summary-button")).not.toBeNull();
  act(() => {
    container.querySelector<HTMLButtonElement>('[data-quick-action="terminal"]')!.click();
    container.querySelector<HTMLButtonElement>(".acpmux-summary-button")!.click();
  });
  expect(called).toEqual(["terminal:off", "summary:off"]);
  act(() => {
    applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } });
    applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "summary" } });
  });
  expect(called).toHaveLength(2);
  called.length = 0;
  await render(true, "first");
  expect(sent).toHaveLength(1);
  expect(sent[0]!.method).toBe("pane.tabRowTools.set");
  expect(sent[0]!.tools.map(({ id }) => id)).toEqual(["summary", "needsYou", "terminal", "browser"]);
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(0);
  expect(container.querySelector(".acpmux-summary-button")).toBeNull();
  expect(container.querySelector(".acpmux-needs-you-button")).toBeNull();
  expect(container.querySelector('button[aria-label="Chat actions"]')).not.toBeNull();
  await render(true, "latest");
  expect(sent).toHaveLength(1);
  act(() => {
    applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } });
    applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "summary" } });
  });
  expect(called).toEqual(["terminal:latest", "summary:latest"]);
  act(() => expect(openPicker(translate("summary.open"))).toBe(true));
  expect(called.at(-1)).toBe("summary:latest");
  called.pop();
  // The App uses enabled=false both for the off tunable and a covered/hidden header.
  await render(false, "hidden");
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(2);
  expect(container.querySelector(".acpmux-summary-button")).not.toBeNull();
  expect(sent.at(-1)!.tools).toEqual([]);
  const count = sent.length;
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } }));
  expect(called).toHaveLength(2);
  await render(false, "still-hidden");
  expect(sent).toHaveLength(count);
  await render(true, "shown");
  expect(sent.at(-1)!.tools).toHaveLength(4);
  await act(async () => root!.unmount());
  root = undefined;
  expect(sent.at(-1)!.tools).toEqual([]);
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } }));
  expect(called).toHaveLength(2);
});

test("a failed native set restores web buttons and recovers on changed state", async () => {
  const container = mount();
  const sent: NativeRowTool[][] = [];
  const calls: string[] = [];
  let reject = true;
  const callNative = async (_method: string, params: Record<string, unknown>) => {
    const tools = params.tools as NativeRowTool[];
    sent.push(tools);
    if (reject && tools.length) throw new Error("unsupported native host");
  };
  await act(async () =>
    root!.render(
      <ChatHeaderTools
        onTerminal={() => void calls.push("terminal")}
        onBrowser={() => {}}
        summary={
          <button type="button" data-summary-fixture>
            Summary
          </button>
        }
        menu={() => []}
        nativeRowTools={{
          enabled: true,
          callNative,
          panel: { id: "summary", label: "Summary", toggled: false, run: () => {} },
        }}
      />,
    ),
  );
  expect(sent[0]).toHaveLength(3);
  expect(sent.at(-1)).toEqual([]);
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(2);
  expect(container.querySelector("[data-summary-fixture]")).not.toBeNull();
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } }));
  expect(calls).toEqual([]);
  reject = false;
  await act(async () => setHeaderState({ lit: [HEADER_ACTIONS.terminal] }));
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(0);
  await act(async () => setHeaderState({ lit: [] }));
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(0);
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } }));
  expect(calls).toEqual(["terminal"]);
});

test("tab-row native opt-in requires a true flag and an offered positive height", async () => {
  const container = mount();
  const sent: NativeRowTool[][] = [];
  const callNative = async (_method: string, params: Record<string, unknown>) => {
    sent.push(params.tools as NativeRowTool[]);
  };
  function SaveRow() {
    previousTabRow = useTabRow();
    return null;
  }
  await act(async () => root!.render(<SaveRow />));
  await act(async () => root!.render(null));
  setTabRow(null);
  function Row() {
    const row = useTabRow();
    const native = useNativeRowTools({ enabled: row.height > 0 && row.nativeRowTools === true, callNative }, [
      { id: "terminal", icon: "terminal", label: "Terminal", run: () => {} },
    ]);
    return <span data-native={String(native)} />;
  }
  await act(async () => root!.render(<Row />));
  for (const value of [
    null,
    {},
    { height: 28 },
    { height: 40, nativeRowTools: false },
    { height: 28, nativeRowTools: "true" },
    { height: 0, nativeRowTools: true },
    { height: -1, nativeRowTools: true },
  ]) {
    await act(async () => applyHostEvent({ kind: "tabRow", value }));
    expect(container.querySelector("[data-native]")?.getAttribute("data-native")).toBe("false");
  }
  expect(sent).toEqual([]);
  await act(async () => applyHostEvent({ kind: "tabRow", value: { height: 28, nativeRowTools: true } }));
  expect(container.querySelector("[data-native]")?.getAttribute("data-native")).toBe("true");
  expect(sent).toHaveLength(1);
  await act(async () => applyHostEvent({ kind: "tabRow", value: { height: 40, nativeRowTools: true } }));
  expect(sent).toHaveLength(1);
  await act(async () => applyHostEvent({ kind: "tabRow", value: { height: 40 } }));
  expect(container.querySelector("[data-native]")?.getAttribute("data-native")).toBe("false");
  expect(sent.at(-1)).toEqual([]);
});
