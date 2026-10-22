// l10n-allow-file: test fixture names, commands and titles, not shipped UI.
// No dead clicks in the Inspector or the tray above the composer (Leo 2026-10-21, on the Subagents
// card's row of icons: "CLICKING ON THESE DOESN'T DO ANYTHING"). Both are drawn with a rich
// fixture (the gallery's busy chat: every section, seventeen running subagents and chats, ninety-four
// ended), every handler a spy, and then every element that looks clickable is clicked, folds and
// lists opening as it goes, until none is left:
// - an enabled button or role=button must call a handler or change what the page shows (a fold
//   opens, a menu opens, a list grows); a link must go somewhere (an http(s) href);
// - a chevron (`disclosure.*`) is drawn only inside something that clicks;
// - a disabled button never takes a hover background (a rule's `:hover` that would match it), so
//   what cannot be clicked never looks as if it could.
import { afterAll, expect, setSystemTime, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  Node: dom.window.Node,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  localStorage: dom.window.localStorage,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|Keyboard|Mouse|Focus|Event)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// One fixed clock: a running row's time then never ticks, so a click that changes nothing never
// passes for one that redrew the page.
setSystemTime(new Date("2026-10-21T12:00:00Z"));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { ChatInspector } = await import("../src/agent-session/acpmux/inspector/ChatInspector");
const { resetInspectorState } = await import("../src/agent-session/acpmux/inspector/inspectorState");
const { SubagentTray } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const gallery = (await import("../src/agent-session/acpmux/inspector/ChatInspector.gallery")).default;
type InspectorProps = import("react").ComponentProps<typeof ChatInspector>;
type TrayItem = import("../src/agent-session/acpmux/subagents/runningTray").TrayItem;
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;

afterAll(() => {
  setSystemTime();
  setPaneLanguage("en");
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
setPaneLanguage("en");

// The styles the Inspector and the tray draw with, for the hover check.
const acpmux = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
for (const file of ["summary/summary.css", "inspector/inspector.css", "subagents/subagents.css"]) {
  const style = dom.window.document.createElement("style");
  style.textContent = readFileSync(path.join(acpmux, file), "utf8");
  dom.window.document.head.append(style);
}

// The host's bridge (native.ts `postNative`): a row that asks the app for something (a command's
// terminal) reaches it, which counts as doing something.
const native: string[] = [];
(dom.window as unknown as { webkit: unknown }).webkit = {
  messageHandlers: {
    agentSession: {
      postMessage: (message: { method: string }) => {
        native.push(message.method);
        return { ok: true, value: { opened: true } };
      },
    },
  },
};

/// A fresh place to draw into.
function mount(): HTMLElement {
  const container = dom.window.document.createElement("main");
  dom.window.document.body.replaceChildren(container);
  return container;
}

/// Every function prop a spy that names itself in `calls`, so a click that reaches a handler shows.
function spied<P extends object>(props: P, calls: string[]): P {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(props))
    out[key] =
      typeof value === "function"
        ? () => {
            calls.push(key);
            return key.startsWith("stop") || key === "onStopProcess" ? Promise.resolve() : undefined;
          }
        : key === "remoteControl" && value
          ? { ...(value as object), set: () => calls.push("remoteControl.set") }
          : value;
  return out as P;
}

const CLICKABLE = 'button:not(:disabled), [role="button"]:not([aria-disabled="true"]), a[href], [role="link"]';

/// What names an element in a failure: its tag, classes, label and text.
function describe(element: Element): string {
  const label = element.getAttribute("aria-label");
  const text = (element.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 60);
  return `<${element.tagName.toLowerCase()} class="${element.getAttribute("class") ?? ""}"${label ? ` aria-label="${label}"` : ""}> ${text}`;
}

const settle = () => act(async () => new Promise<void>((resolve) => setTimeout(resolve, 0)));

/// Clicks every clickable element in `container` (and what opening folds and lists adds), and
/// returns the ones whose click did nothing.
async function deadClicks(container: HTMLElement, calls: string[]): Promise<{ dead: string[]; clicked: number }> {
  const tried = new Set<string>();
  const dead: string[] = [];
  const closes = (element: Element) => element.getAttribute("aria-expanded") === "true";
  // Everything but what closes, round by round as folds and lists open; then what closes them.
  for (let round = 0; round < 10; round += 1) {
    const last = round === 9;
    const fresh = [...container.querySelectorAll<HTMLElement>(CLICKABLE)].filter(
      (element) => !tried.has(describe(element)) && (last || !closes(element)),
    );
    if (fresh.length === 0 && !last) {
      round = 8;
      continue;
    }
    for (const element of fresh) {
      const name = describe(element);
      if (tried.has(name) || !element.isConnected) continue;
      tried.add(name);
      if (element instanceof dom.window.HTMLAnchorElement) {
        const href = element.getAttribute("href") ?? "";
        if (!/^https?:\/\//.test(href)) dead.push(`${name} (href ${href})`);
        continue;
      }
      const before = calls.length + native.length;
      const page = dom.window.document.body.innerHTML;
      await act(async () => element.click());
      await settle();
      if (calls.length + native.length === before && dom.window.document.body.innerHTML === page) dead.push(name);
      // A menu it opened closes again, so it covers nothing that comes after.
      const menu = dom.window.document.querySelector('[role="menu"]');
      if (menu) {
        await act(async () => {
          menu.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
        });
        await settle();
      }
    }
  }
  return { dead, clicked: tried.size };
}

/// Chevrons drawn outside anything that clicks.
const loneChevrons = (container: HTMLElement) =>
  [...container.querySelectorAll('[data-icon^="disclosure."]')]
    .filter((icon) => !icon.closest(CLICKABLE))
    .map((icon) => describe(icon.parentElement ?? icon));

/// Disabled buttons a `:hover` rule would still light up.
function hoverOnDisabled(container: HTMLElement): string[] {
  const out: string[] = [];
  const disabled = [...container.querySelectorAll("button:disabled")];
  for (const sheet of dom.window.document.styleSheets)
    for (const rule of sheet.cssRules) {
      if (!(rule instanceof dom.window.CSSStyleRule) || !/background|color/.test(rule.style.cssText)) continue;
      for (const part of rule.selectorText.split(",")) {
        if (!part.includes(":hover") || /:not\(:disabled\)|:enabled/.test(part)) continue;
        const base = part.replaceAll(":hover", "").trim();
        let matched: Element[] = [];
        try {
          matched = disabled.filter((element) => element.matches(base));
        } catch {
          continue; // a selector jsdom cannot match
        }
        for (const element of matched) out.push(`${part.trim()} lights ${describe(element)}`);
      }
    }
  return out;
}

test("every clickable thing in the Inspector does something, and nothing else looks clickable", async () => {
  resetInspectorState();
  const container = mount();
  const calls: string[] = [];
  const busy = gallery.variants["subagents-busy"]!.props as InspectorProps;
  const props = spied<InspectorProps>(busy, calls);
  const root = createRoot(container);
  await act(async () => root.render(createElement(ChatInspector, props)));
  await settle();
  // The fixture reaches every section, Subagents with its Show more and its ended row.
  const sections = [...container.querySelectorAll("section[data-section]")].map((section) =>
    section.getAttribute("data-section"),
  );
  for (const id of ["environment", "context", "connectors", "changes", "servers", "subagents", "tasks", "outputs"])
    expect(sections).toContain(id);
  expect(container.querySelector(".acpmux-chat-inspector-subagents__more")).not.toBeNull();
  expect(container.querySelector(".acpmux-chat-inspector-subagents__ended")).not.toBeNull();
  expect(container.querySelector(".cv-subagent-avatar")).toBeNull();
  expect(loneChevrons(container)).toEqual([]);
  const { dead, clicked } = await deadClicks(container, calls);
  expect(dead).toEqual([]);
  // The folds opened as it went: every ended subagent's line was clicked too.
  expect(clicked).toBeGreaterThan(150);
  for (const handler of ["onOpenSubagent", "onOpenSession", "onOpenUrl", "onOpenOutput", "onStopProcess"])
    expect(calls).toContain(handler);
  // A background task's row opens its terminal through the host.
  expect(native).toContain("chat.processTerminal");
  expect(loneChevrons(container)).toEqual([]);
  expect(hoverOnDisabled(container)).toEqual([]);
  await act(async () => root.unmount());
});

const started = Date.now();
const agent = (index: number, fields: Partial<Subagent> = {}): Subagent => ({
  id: `tray-${index}`,
  parent: null,
  name: `Lane ${index}`,
  task: "Land one piece",
  state: "running",
  startedAt: started - (index + 1) * 60_000,
  action: "Reading SubagentTray.tsx",
  ...fields,
});

test("every line of the tray, and its header, does something", async () => {
  const container = mount();
  const calls: string[] = [];
  const items: TrayItem[] = [
    { kind: "agent", id: "tray-0", agent: agent(0), depth: 0 },
    { kind: "agent", id: "tray-1", agent: agent(1, { parent: "tray-0" }), depth: 1 },
    {
      kind: "command",
      id: "cmd",
      command: { id: "cmd", command: "bun run dev", state: "running", startedAt: started - 30_000, processId: "p/1" },
    },
    {
      kind: "session",
      id: "lane-a",
      session: { sessionId: "lane-a", title: "summary-panel", state: "running", createdAt: started - 300_000 },
    },
    {
      kind: "session",
      id: "lane-b",
      session: { sessionId: "lane-b", title: "priority-view", state: "running", createdAt: started - 200_000 },
    },
  ];
  const props = spied(
    {
      items,
      working: true,
      waiting: new Set<string>(),
      onOpen: () => undefined,
      onOpenCommand: () => undefined,
      onOpenSession: () => undefined,
      stop: async () => undefined,
      stopProcess: async () => undefined,
    },
    calls,
  );
  const root = createRoot(container);
  await act(async () => root.render(createElement(SubagentTray, props)));
  await settle();
  // Five items start folded to the header; clicking it opens them, and then each line is clicked.
  expect(loneChevrons(container)).toEqual([]);
  const { dead } = await deadClicks(container, calls);
  expect(dead).toEqual([]);
  for (const handler of ["onOpen", "onOpenCommand", "onOpenSession", "stop", "stopProcess"])
    expect(calls).toContain(handler);
  // The session lines open their session (App.tsx `openOfferChat`), never nothing.
  expect(calls.filter((call) => call === "onOpenSession")).toHaveLength(2);
  expect(hoverOnDisabled(container)).toEqual([]);
  await act(async () => root.unmount());
});

test("a line that cannot open (no handler) is disabled and never lights on hover", async () => {
  resetInspectorState();
  const container = mount();
  const agents: Subagent[] = [agent(0), agent(1, { state: "completed", endedAt: started })];
  const root = createRoot(container);
  await act(async () => root.render(createElement(ChatInspector, { agents })));
  await settle();
  const lines = [...container.querySelectorAll<HTMLButtonElement>("button.acpmux-agent-line__button")];
  expect(lines.length).toBeGreaterThan(0);
  for (const line of lines) expect(line.disabled).toBe(true);
  expect(hoverOnDisabled(container)).toEqual([]);
  await act(async () => root.unmount());
});
