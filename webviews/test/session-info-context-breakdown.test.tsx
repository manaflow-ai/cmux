// l10n-allow-file: test fixture category names, as Claude Code sends them.
// A Claude Code chat's /context breakdown (acpmux `contextBreakdown`) in Session Info's Context and
// the composer ring's details: used categories largest first, the buffer, the deferred ones with no
// share, the free space last; malformed input dropped; the MCP tools, memory files and skills folds
// open on a click. Without a breakdown both keep what they drew before.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextRing } from "../src/agent-session/acpmux/ComposerPickers";
import { contextBreakdown, ContextSection } from "../src/agent-session/acpmux/session-info/ContextSection";
import { SessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { COMPACT_PROMPT, compactThrough } from "../src/agent-session/acpmux/conversation/turnActions";

const BREAKDOWN = {
  categories: [
    { id: "system_prompt", name: "System prompt", tokens: 10_700, kind: "used" },
    { name: "System tools (deferred)", tokens: 20_800, kind: "deferred" },
    { id: "free_space", name: "Free space", tokens: 146_700, kind: "free" },
    { id: "messages", name: "Messages", tokens: 169_800, kind: "used" },
    { name: "Autocompact buffer", tokens: 33_000, kind: "buffer" },
    { name: "Memory files", tokens: 15_000, kind: "used" },
  ],
  memoryFiles: [{ path: "/repo/CLAUDE.md", type: "Project", tokens: 12_000 }],
  mcpTools: [
    { name: "mcp__cmux__render", serverName: "cmux", tokens: 300 },
    { name: "mcp__linear__issue", serverName: "linear", tokens: 131 },
  ],
  totalTokens: 171_500,
  maxTokens: 400_000,
};

test("used categories come largest first, then the buffer, the deferred ones and the free space", () => {
  const rows = contextBreakdown(BREAKDOWN)!.rows;
  expect(rows.map((row) => row.name)).toEqual([
    "Messages",
    "Memory files",
    "System prompt",
    "Autocompact buffer",
    "System tools (deferred)",
    "Free space",
  ]);
  expect(rows.map((row) => row.tone)).toEqual([0, 1, 2, undefined, undefined, undefined]);
  expect(rows[0]!.share).toBeCloseTo(0.4245);
  // A deferred category takes no room until it loads: no share.
  expect(rows[4]!.share).toBeUndefined();
  expect(rows[5]!.share).toBeCloseTo(0.36675);
});

test("the folds name each MCP tool without its server prefix, each memory file by its name", () => {
  const lists = contextBreakdown(BREAKDOWN)!.lists;
  expect(lists.map((list) => list.id)).toEqual(["mcpTools", "memoryFiles"]);
  expect(lists[0]!.items[0]).toEqual({ name: "render", detail: "cmux", tokens: 300 });
  expect(lists[1]!.items[0]).toEqual({ name: "CLAUDE.md", detail: "/repo/CLAUDE.md", tokens: 12_000 });
});

test("a malformed breakdown draws nothing; malformed rows are dropped and counts clamped", () => {
  expect(contextBreakdown(undefined)).toBeUndefined();
  expect(contextBreakdown({ ...BREAKDOWN, maxTokens: 0 })).toBeUndefined();
  expect(contextBreakdown({ ...BREAKDOWN, categories: "x" })).toBeUndefined();
  expect(contextBreakdown({ ...BREAKDOWN, categories: [{ name: "", tokens: 1, kind: "used" }] })).toBeUndefined();
  const parsed = contextBreakdown({
    categories: [
      { name: "Messages", tokens: 900_000, kind: "used" },
      { name: "Odd", tokens: 5, kind: "other" },
      null,
      { name: "Skills", tokens: -4, kind: "used" },
    ],
    mcpTools: [{ tokens: 5 }, "x"],
    skills: [{ name: "review", tokens: "many" }],
    maxTokens: 200_000,
  })!;
  expect(parsed.rows.map((row) => [row.name, row.tokens, row.share])).toEqual([
    ["Messages", 900_000, 1],
    ["Skills", 0, 0],
  ]);
  expect(parsed.lists).toEqual([{ id: "skills", items: [{ name: "review", tokens: 0 }] }]);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
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
});

const rowNames = (container: ParentNode) =>
  [...container.querySelectorAll(".acpmux-context-breakdown > ul > li .acpmux-session-info-row__name")].map(
    (name) => name.textContent,
  );

test("Session Info's Context draws a row per category, deferred ones dimmed with no share, and its folds open", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () =>
    root!.render(<ContextSection usage={{ used: 171_500, size: 400_000 }} percent={43} breakdown={BREAKDOWN} />),
  );
  expect(rowNames(container)).toHaveLength(6);
  const deferred = container.querySelector('li[data-kind="deferred"]')!;
  expect(deferred.querySelector(".acpmux-session-info-context__share")!.textContent).toBe("—");
  // The bar has a segment per used category and the buffer; free space is its track.
  expect(container.querySelectorAll(".acpmux-session-info-context__bar > span")).toHaveLength(4);
  const fold = container.querySelector<HTMLButtonElement>('[data-list="mcpTools"] button')!;
  expect(fold.getAttribute("aria-expanded")).toBe("false");
  expect(fold.textContent).toContain("2");
  await act(async () => fold.click());
  expect(fold.getAttribute("aria-expanded")).toBe("true");
  const items = container.querySelectorAll('[data-list="mcpTools"] .acpmux-context-breakdown__items li');
  expect([...items].map((item) => item.querySelector(".acpmux-session-info-row__name")!.textContent)).toEqual([
    "render",
    "issue",
  ]);
  await act(async () => fold.click());
  expect(container.querySelector('[data-list="mcpTools"] .acpmux-context-breakdown__items')).toBeNull();
});

test("without a breakdown Session Info's Context keeps its used and free rows", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<ContextSection usage={{ used: 94_000, size: 200_000 }} percent={47} />));
  expect(container.querySelector(".acpmux-context-breakdown")).toBeNull();
  expect([...container.querySelectorAll("li[data-part]")].map((row) => row.getAttribute("data-part"))).toEqual([
    "used",
    "free",
  ]);
});

test("the composer ring keeps Claude's breakdown details and uses a compact tooltip without one", async () => {
  const container = installDom();
  root = createRoot(container);
  const open = async () => {
    await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-context-ring")!.click());
    return document.querySelector(".acpmux-context-pop")!;
  };
  await act(async () => root!.render(<ContextRing used={171_500} size={400_000} breakdown={BREAKDOWN} />));
  const pop = await open();
  expect(pop.classList.contains("acpmux-context-pop--breakdown")).toBe(true);
  expect(pop.querySelector(".acpmux-context-card-parts")?.textContent).toContain("Messages");
  expect(pop.querySelector(".acpmux-context-card-bar")).not.toBeNull();
  await act(async () => root!.unmount());
  root = createRoot(container);
  await act(async () => root!.render(<ContextRing used={60_000} size={200_000} />));
  const plain = await open();
  expect(plain.querySelector(".acpmux-context-breakdown")).toBeNull();
  expect(plain.classList.contains("acpmux-context-pop--compact")).toBe(true);
  expect(plain.querySelector(".acpmux-context-card-line")?.textContent).toContain("30%");
  expect(plain.querySelector(".acpmux-context-card-line")?.textContent).toContain("60K");
  expect(plain.querySelector(".acpmux-context-card-bar")).not.toBeNull();
});

// Leo, 2026-10-28: "You don't have the compact session." Compact session in Session Info's Context:
// only where the App hands a compact (the agent lists /compact and the chat can be sent to).
// The composer ring's card has none (Leo, 2026-10-31: "JUST F***ING REMOVE COMPACT FROM THE F***ING
// POPOVER").
const compactButton = (container: ParentNode) =>
  [...container.querySelectorAll<HTMLButtonElement>(".acpmux-session-info-context__actions button")].find(
    (button) => button.textContent === "Compact session",
  );

test("Session Info's Context offers Compact only with a compact, and sends it on a click", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<ContextSection usage={{ used: 94_000, size: 200_000 }} percent={47} />));
  expect(container.querySelector(".acpmux-session-info-context__actions")).toBeNull();
  const sent: string[] = [];
  await act(async () =>
    root!.render(
      <ContextSection usage={{ used: 94_000, size: 200_000 }} percent={47} onCompact={() => sent.push("compact")} />,
    ),
  );
  const button = compactButton(container)!;
  expect(button.disabled).toBe(false);
  await act(async () => button.click());
  expect(sent).toEqual(["compact"]);
});

test("Session Info's Compact session stays live while a turn runs, and its click sends /compact", async () => {
  // Leo, 2026-10-31: "COMPACT BUTTON LITERALLY DOESN'T EVEN F***IN WORK". It was disabled while a
  // turn ran, and his chats nearly always run; the /compact now queues behind the turn as one typed
  // in the composer does. The click goes through App.tsx's own path: compactThrough's chat.send.
  const container = installDom();
  root = createRoot(container);
  const calls: Array<[string, Record<string, unknown>]> = [];
  const callNative = async (method: string, params: Record<string, unknown>) => {
    calls.push([method, params]);
  };
  await act(async () =>
    root!.render(
      // SessionInfo takes no working state at all: nothing a running turn sets can turn Compact off.
      <SessionInfo
        summary={{ usage: { used: 94_000, size: 200_000 } } as never}
        sections={{ context: true } as never}
        onCompact={compactThrough(callNative)}
      />,
    ),
  );
  const button = container.querySelector<HTMLButtonElement>(".acpmux-session-info-context__compact")!;
  expect(button.textContent).toBe("Compact session");
  expect(button.disabled).toBe(false);
  await act(async () => button.click());
  expect(calls).toEqual([["chat.send", { text: COMPACT_PROMPT }]]);
  expect(COMPACT_PROMPT).toBe("/compact");
});

test("with Claude's /context, the tokens until auto-compact sit beside Compact session", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <ContextSection
        usage={{ used: 171_500, size: 400_000 }}
        percent={43}
        breakdown={BREAKDOWN}
        onCompact={() => {}}
      />,
    ),
  );
  const actions = container.querySelector(".acpmux-session-info-context__actions")!;
  expect(actions.querySelector(".acpmux-session-info-context__until")?.textContent).toBe("146.7K until auto-compact");
  // Without a buffer row the harness does not say when it compacts: the button alone.
  await act(async () =>
    root!.render(<ContextSection usage={{ used: 94_000, size: 200_000 }} percent={47} onCompact={() => {}} />),
  );
  expect(container.querySelector(".acpmux-session-info-context__until")).toBeNull();
  expect(container.querySelector(".acpmux-session-info-context__compact")).not.toBeNull();
});

test("the composer ring's card has no Compact, only Details", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<ContextRing used={60_000} size={200_000} onOpenDetails={() => {}} />));
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-context-ring")!.click());
  const buttons = [...document.querySelectorAll<HTMLButtonElement>(".acpmux-context-card button")];
  expect(buttons.map((button) => button.className)).toEqual(["acpmux-context-card-details"]);
  expect(buttons.some((button) => button.textContent === "Compact")).toBe(false);
});
