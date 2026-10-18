// l10n-allow-file: test fixtures, not shipped UI.
import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxPlanEntry, AcpmuxRow } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "https://pane.test/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  localStorage: dom.window.localStorage,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
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
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
const { createRoot } = await import("react-dom/client");
const { configureLabs, labOn } = await import("../src/agent-session/acpmux/labs");
const { PlanProgress, runningPlan } = await import("../src/agent-session/acpmux/PlanProgress");
const { ShortcutsHelp, useShortcutsHelp } = await import("../src/agent-session/acpmux/ShortcutsHelp");
const { ShortcutsContext } = await import("../src/agent-session/acpmux/shortcuts");
const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
const { useComposerKeyboard } = await import("../src/agent-session/acpmux/composerFocus");
const { UiProvider } = await import("../src/ui/UiProvider");
const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
let root: Root | undefined;
let inserted: string[] = [];
dom.window.document.execCommand = (_command, _showUI, value) => {
  inserted.push(value ?? "");
  return true;
};

beforeEach(() => {
  act(() => configureLabs(undefined));
  setComposerSettings({ showDictation: true });
  inserted = [];
});
afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
});
afterAll(() => {
  configureLabs(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
async function draw(node: ReactNode) {
  root ??= createRoot(host);
  await act(async () => root!.render(<UiProvider container={host}>{node}</UiProvider>));
}
const row = (kind: string, id: string, rest: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: 1,
  ...rest,
});
const entries: AcpmuxPlanEntry[] = Array.from({ length: 7 }, (_, index) => ({
  content: index === 3 ? "Check retries on a slow connection" : `Step ${index + 1}`,
  status: index < 3 ? "completed" : index === 3 ? "in_progress" : "pending",
}));
const plan = row("plan", "plan", { plan: entries });
const button = (label: string) =>
  [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (node) => node.getAttribute("aria-label") === label || node.textContent === label,
  );

test("the first mock turn supplies a running plan only with planProgress on", async () => {
  const { mockTurn } = await import("../src/agent-session/acpmux/mock");
  const plans = (turn: number) =>
    mockTurn("Check the greeting", turn).flatMap((step) =>
      "update" in step && step.update.sessionUpdate === "plan" ? [step.update] : [],
    );
  expect(plans(1)).toEqual([]);
  act(() => configureLabs({ labs: { planProgress: true } }));
  expect(plans(1)).toHaveLength(1);
  expect(plans(1)[0]!.entries).toEqual([
    { content: "Read src/greeting.ts", status: "in_progress", priority: "medium" },
    { content: "Edit src/greeting.ts", status: "pending", priority: "medium" },
    { content: "Write NOTES.md", status: "pending", priority: "medium" },
  ]);
  expect(plans(2)).toEqual([]);
});
const dialog = () => host.querySelector<HTMLElement>('[role="dialog"]');
async function key(value: string, init: KeyboardEventInit = {}) {
  const event = new dom.window.KeyboardEvent("keydown", { key: value, bubbles: true, cancelable: true, ...init });
  await act(async () => {
    (dom.window.document.activeElement ?? host).dispatchEvent(event);
  });
  return event;
}

test("both labs default off and add no markup even with a plan or an open dialog", async () => {
  expect(labOn("planProgress")).toBe(false);
  expect(labOn("shortcutsHelp")).toBe(false);
  await draw(
    <>
      <PlanProgress rows={[plan]} working onReveal={() => {}} />
      <ShortcutsHelp open onOpenChange={() => {}} />
    </>,
  );
  expect(host.innerHTML).toBe("");
});

test("planProgress shows the current step, completed count and native progress, then follows updates", async () => {
  act(() => configureLabs({ labs: { planProgress: true } }));
  let revealed: string | undefined;
  const strip = (rows: AcpmuxRow[], working = true) => (
    <PlanProgress
      rows={rows}
      working={working}
      onReveal={(id) => {
        revealed = id;
      }}
    />
  );
  await draw(strip([plan]));
  expect(host.querySelector(".acpmux-plan-progress__text")?.textContent).toBe(entries[3]!.content);
  expect(host.querySelector(".acpmux-plan-progress__count")?.textContent).toBe("3 of 7");
  expect(host.querySelector("progress")?.value).toBe(3);
  expect(host.querySelector("progress")?.max).toBe(7);
  await act(async () => host.querySelector("button")!.click());
  expect(revealed).toBe("plan");
  const updated = entries.map((entry, index): AcpmuxPlanEntry => ({
    ...entry,
    status: index < 4 ? "completed" : index === 4 ? "in_progress" : "pending",
  }));
  await draw(strip([plan, row("plan", "updated", { plan: updated })]));
  expect(host.querySelector(".acpmux-plan-progress__text")?.textContent).toBe("Step 5");
  expect(host.querySelector("progress")?.value).toBe(4);
  await draw(strip([plan], false));
  expect(host.innerHTML).toBe("");
  await draw(strip([]));
  expect(host.innerHTML).toBe("");
});

test("a new accepted turn never reuses an old plan; queued and failed prompts keep the running one", () => {
  expect(runningPlan([plan, row("user", "next")], true)).toBeUndefined();
  expect(runningPlan([plan, row("turnSummary", "ended")], true)).toBeUndefined();
  expect(runningPlan([plan, row("user", "queued", { pending: true })], true)).toBe(plan);
  expect(runningPlan([plan, row("user", "failed", { failed: true })], true)).toBe(plan);
  expect(runningPlan([plan, row("plan", "cleared", { plan: [] })], true)).toBeUndefined();
  expect(runningPlan([plan], false)).toBeUndefined();
});

test("pending and finished plans stay finite, and disabling planProgress removes the strip", async () => {
  act(() => configureLabs({ labs: { planProgress: true } }));
  for (const status of ["pending", "completed"] as const) {
    await draw(
      <PlanProgress
        rows={[row("plan", status, { plan: [{ content: "Only step", status }] })]}
        working
        onReveal={() => {}}
      />,
    );
    expect(host.querySelector(".acpmux-plan-progress__text")?.textContent).toBe("Only step");
    expect(host.querySelector("progress")?.value).toBe(status === "completed" ? 1 : 0);
  }
  await act(async () => configureLabs(undefined));
  expect(host.innerHTML).toBe("");
});

test("clicking progress reveals an unmounted plan in the virtual transcript and stays there as work grows", async () => {
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  act(() => configureLabs({ labs: { planProgress: true } }));
  const reveal = { current: undefined as ((id: string) => void) | undefined };
  const rows = [
    plan,
    ...Array.from({ length: 100 }, (_, index) =>
      row("assistant", `reply-${index}`, { text: "A long reply\n".repeat(8) }),
    ),
  ];
  const prototype = dom.window.HTMLElement.prototype;
  const viewport = Object.getOwnPropertyDescriptor(prototype, "clientHeight");
  Object.defineProperty(prototype, "clientHeight", { configurable: true, get: () => 600 });
  const pane = (shown: AcpmuxRow[]) => (
    <>
      <VirtualTranscript
        rows={shown}
        sessionId="progress"
        expanded={new Set()}
        onToggleActivity={() => {}}
        revealRow={reveal}
      />
      <PlanProgress rows={shown} working onReveal={(id) => reveal.current?.(id)} />
    </>
  );
  try {
    await draw(pane(rows));
    expect(host.querySelector('[data-row-id="plan"]')).toBeNull();
    await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-plan-progress")!.click());
    expect(host.querySelector('[data-row-id="plan"]')).not.toBeNull();
    expect(host.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop).toBe(0);
    await draw(pane([...rows, row("assistant", "more", { text: "Still working" })]));
    expect(host.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop).toBe(0);
  } finally {
    if (viewport) Object.defineProperty(prototype, "clientHeight", viewport);
    else Reflect.deleteProperty(prototype, "clientHeight");
  }
});

const bindings = {
  "palette.newAgentChat": "⌃N",
  "palette.toggleDictation": "⌥D",
  "palette.copySurfaceLink": "⌃L",
  "agentPane.permission.allowOnce": "⌘Y",
  splitRight: "⌘D",
};
let command: (name: string) => boolean;
function HelpPane() {
  const help = useShortcutsHelp();
  command = help.command;
  useComposerKeyboard(() => true, help.command);
  return (
    <>
      <ChatHeaderTools
        onTerminal={() => {}}
        onBrowser={() => {}}
        tabTools={false}
        summary={null}
        menu={() => (help.menu ? [help.menu] : [])}
      />
      <input aria-label="Input" />
      <textarea aria-label="Prompt" />
      <select aria-label="Select">
        <option>Choice</option>
      </select>
      <div contentEditable aria-label="Editor" />
      {help.dialog}
    </>
  );
}
const helpPane = (labels = bindings) => (
  <ShortcutsContext.Provider value={labels}>
    <HelpPane />
  </ShortcutsContext.Provider>
);

test("shortcutsHelp renders live bindings in groups and reacts to rebinds and unbinding", async () => {
  act(() => configureLabs({ labs: { shortcutsHelp: true } }));
  await draw(helpPane());
  await act(async () => {
    expect(command("shortcutsHelp")).toBe(true);
  });
  expect(dialog()?.getAttribute("aria-label")).toBe("Keyboard shortcuts");
  expect([...dialog()!.querySelectorAll("h3")].map((node) => node.textContent)).toEqual([
    "Composer",
    "Conversation",
    "Navigation",
  ]);
  expect([...dialog()!.querySelectorAll("kbd")].map((node) => node.textContent)).toContain("⌃N");
  expect(dialog()!.textContent).not.toContain("⇧⌘I");
  await draw(helpPane({ ...bindings, "palette.newAgentChat": "⌥N", "palette.toggleDictation": "", splitRight: "" }));
  expect([...dialog()!.querySelectorAll("kbd")].map((node) => node.textContent)).toContain("⌥N");
  expect(dialog()!.textContent).not.toContain("⌃N");
  expect(dialog()!.textContent).not.toContain("Dictate");
  expect(dialog()!.textContent).not.toContain("Terminal");
});

test("the header overflow opens shortcuts help and Close dismisses it", async () => {
  act(() => configureLabs({ labs: { shortcutsHelp: true } }));
  await draw(helpPane());
  await act(async () => button("Chat actions")!.click());
  const item = [...host.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (node) => node.textContent === "Keyboard shortcuts",
  );
  expect(item).toBeDefined();
  await act(async () => item!.click());
  expect(dialog()).not.toBeNull();
  await act(async () => button("Close")!.click());
  expect(dialog()).toBeNull();
  expect(dom.window.document.activeElement === button("Chat actions")).toBe(true);
});

test("? follows the existing keyboard route, Escape dismisses, and the disabled lab keeps typing", async () => {
  await draw(helpPane());
  expect(command("shortcutsHelp")).toBe(false);
  expect(button("Chat actions")?.disabled).toBe(true);
  dom.window.document.body.focus();
  await key("?");
  expect(inserted).toEqual(["?"]);
  expect(dialog()).toBeNull();
  await act(async () => configureLabs({ labs: { shortcutsHelp: true } }));
  inserted = [];
  if (dom.window.document.activeElement instanceof dom.window.HTMLElement) dom.window.document.activeElement.blur();
  expect((await key("?", { shiftKey: true })).defaultPrevented).toBe(true);
  expect(dialog()).not.toBeNull();
  expect(inserted).toEqual([]);
  await key("Escape");
  expect(dialog()).toBeNull();
});

test("help leaves text fields, composing input, modifier chords and owned widgets alone", async () => {
  act(() => configureLabs({ labs: { shortcutsHelp: true } }));
  await draw(helpPane());
  for (const selector of ["input", "textarea", "select", "[contenteditable]"]) {
    const field = host.querySelector<HTMLElement>(selector)!;
    field.focus();
    expect((await key("?")).defaultPrevented).toBe(false);
    expect(dialog()).toBeNull();
  }
  if (dom.window.document.activeElement instanceof dom.window.HTMLElement) dom.window.document.activeElement.blur();
  for (const init of [{ metaKey: true }, { ctrlKey: true }, { altKey: true }, { isComposing: true }]) {
    expect((await key("?", init)).defaultPrevented).toBe(false);
    expect(dialog()).toBeNull();
  }
  await act(async () => button("Chat actions")!.click());
  const item = host.querySelector<HTMLElement>('[role="menuitem"]')!;
  item.focus();
  await key("?");
  expect(dialog()).toBeNull();
  expect(inserted).toEqual([]);
});

test("turning shortcutsHelp off removes an open dialog and its menu entry", async () => {
  act(() => configureLabs({ labs: { shortcutsHelp: true } }));
  await draw(helpPane());
  await act(async () => {
    command("shortcutsHelp");
  });
  expect(dialog()).not.toBeNull();
  await act(async () => configureLabs(undefined));
  expect(dialog()).toBeNull();
  expect(command("shortcutsHelp")).toBe(false);
  expect(button("Chat actions")?.disabled).toBe(true);
});
