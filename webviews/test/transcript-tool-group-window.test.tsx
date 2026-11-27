// l10n-allow-file: test fixture commands, thoughts and MCP calls, not shipped UI.
// An opened list of steps inside a transcript row mounts only its view's steps and a view's worth over
// and under them, at any length (stepWindow.ts): an opened "Ran N commands" group (ToolGroupRow.tsx
// StepList), an opened mixed run (ToolRunSteps.tsx) and an opened group of MCP calls (McpCallRows.tsx).
// For each: the steps and DOM nodes mounted at N = 1,000 and 10,000 are the same within 10% and no
// more than the view and its overscan hold; a change to one call draws that call alone; and a scroll
// by one view draws no step that stays mounted. A test DOM reads no layout, so the view is the run
// box's 224px (`.cv-run-scroll`, its offset set below), or the window's height for the MCP group,
// which has no box, and a step is its 22px estimate. Counted through acpmuxPerf's row renders
// (toolRowCount.ts: `tool:<id>` per commit, `tool-mount:<id>` per mount).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "customElements",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

/// A step's estimate (stepWindow.ts STEP_PX), the run box's cap (BOX_PX) and the test DOM's window.
const STEP = 22;
const BOX = 224;
/// The most steps a view of `view` px and a view's worth over and under it hold, and one cut each end.
const most = (view: number) => Math.ceil((3 * view) / STEP) + 2;

const command = (n: number, output = `line ${n}\n`): AcpmuxActivity => ({
  kind: "tool",
  text: `echo ${n}`,
  tool: { id: `cmd-${n}`, title: `echo ${n}`, kind: "execute", command: `echo ${n}`, status: "completed", output },
});
const thought = (n: number): AcpmuxActivity => ({
  kind: "thought",
  text: `Step ${n} needs its fixture first, so read it before the next command.`,
  startedAt: 0,
  endedAt: 4_000,
});
const mcp = (n: number, output = `found ${n}`): AcpmuxActivity => ({
  kind: "tool",
  text: "mcp__docs__search",
  tool: {
    id: `mcp-${n}`,
    title: "mcp__docs__search",
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify({ query: `case ${n}` }),
    output,
  },
});
const commands = (n: number) => Array.from({ length: n }, (_, at) => command(at));
// A mixed run: commands with a thought every seventh step.
const mixed = (n: number) => Array.from({ length: n }, (_, at) => (at % 7 === 3 ? thought(at) : command(at)));
const mcps = (n: number) => Array.from({ length: n }, (_, at) => mcp(at));

async function draw(node: ReactNode) {
  const { createRoot } = await import("react-dom/client");
  root ??= createRoot(host);
  await act(async () => root!.render(node));
}

async function fresh() {
  const { resetTranscriptDisclosure } =
    await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");
  act(() => root?.unmount());
  root = undefined;
  resetTranscriptDisclosure();
}

const perf = async () => (await import("../src/agent-session/acpmux/perf")).acpmuxPerf;

/// Row commits and mounts since the last reset, by call id.
async function counted() {
  const renders = (await perf()).renders;
  const of = (prefix: string) =>
    new Map(
      [...renders].filter(([name]) => name.startsWith(prefix)).map(([name, n]) => [name.slice(prefix.length), n]),
    );
  return { commits: of("tool:"), mounts: of("tool-mount:") };
}

/// Scrolls the run's box (a test DOM's scrollTop is fixed at 0) and lets its listener read it.
async function scrollBox(top: number) {
  const box = host.querySelector<HTMLElement>(".cv-run-scroll")!;
  Object.defineProperty(box, "scrollTop", { configurable: true, value: top, writable: true });
  await act(async () => box.dispatchEvent(new window.Event("scroll")));
}

type List = {
  name: string;
  /// The list drawn opened with these items.
  node: (items: AcpmuxActivity[]) => ReactNode;
  items: (n: number) => AcpmuxActivity[];
  /// Opens the list when it starts closed.
  open?: () => Promise<void>;
  /// Its mounted steps.
  steps: () => number;
  /// The view its window holds, in px.
  view: number;
  /// A changed copy of item `at`.
  change: (item: AcpmuxActivity, at: number) => AcpmuxActivity;
  /// Whether the list scrolls in its own box.
  box: boolean;
};

const lists: List[] = [
  {
    name: 'an opened "Ran N commands" group (ToolGroupRow.tsx)',
    node: (items) => <Group items={items} />,
    items: commands,
    steps: () => host.querySelectorAll(".cv-steps > .cv-step").length,
    view: BOX,
    change: (_, at) => command(at, `line ${at}\nchanged\n`),
    box: true,
  },
  {
    name: "an opened mixed run (ToolRunSteps.tsx)",
    node: (items) => <Run items={items} />,
    items: mixed,
    steps: () => host.querySelectorAll(".cv-steps > .cv-step").length,
    view: BOX,
    change: (_, at) => command(at, `line ${at}\nchanged\n`),
    box: true,
  },
  {
    name: "an opened group of MCP calls (McpCallRows.tsx)",
    node: (items) => <Mcp items={items} />,
    items: mcps,
    open: async () => {
      const line = host.querySelector<HTMLButtonElement>('button[aria-expanded="false"]')!;
      await act(async () => line.click());
    },
    steps: () => host.querySelectorAll(".cv-tool-group .cv-tool").length,
    view: 768,
    change: (_, at) => mcp(at, `found ${at}, changed`),
    box: false,
  },
];

let Group: (props: { items: AcpmuxActivity[] }) => ReactNode;
let Run: (props: { items: AcpmuxActivity[] }) => ReactNode;
let Mcp: (props: { items: AcpmuxActivity[] }) => ReactNode;

beforeAll(async () => {
  const { ToolGroupRow } = await import("../src/agent-session/acpmux/conversation/ToolGroupRow");
  const { ToolRunSteps } = await import("../src/agent-session/acpmux/conversation/ToolRunSteps");
  const { RunScroll } = await import("../src/agent-session/acpmux/conversation/RunScroll");
  const { McpCallRows } = await import("../src/agent-session/acpmux/conversation/McpCallRows");
  Group = ({ items }) => <ToolGroupRow kind="commands" items={items} disclosureKey="window-group" />;
  Run = ({ items }) => (
    <RunScroll>
      <div className="cv-tool-run">
        <ToolRunSteps items={items} rowId="window-run" thoughtsBefore={0} />
      </div>
    </RunScroll>
  );
  Mcp = ({ items }) => <McpCallRows items={items} disclosureKey="window-mcp" />;
});

for (const list of lists) {
  test(`${list.name}: mounts the same steps and nodes at 1,000 and 10,000, no more than its view holds`, async () => {
    const at = async (n: number) => {
      await fresh();
      await draw(list.node(list.items(n)));
      await list.open?.();
      return { steps: list.steps(), nodes: host.querySelectorAll("*").length };
    };
    const thousand = await at(1_000);
    // Asserted before 10,000 draws, so a list that draws them all fails here, fast.
    expect(thousand.steps).toBeGreaterThan(0);
    expect(thousand.steps).toBeLessThanOrEqual(most(list.view));
    const tenThousand = await at(10_000);
    console.log(
      `${list.name}: steps ${thousand.steps} / ${tenThousand.steps}, nodes ${thousand.nodes} / ${tenThousand.nodes}`,
    );
    expect(tenThousand.steps).toBeLessThanOrEqual(most(list.view));
    expect(Math.abs(tenThousand.steps - thousand.steps)).toBeLessThanOrEqual(thousand.steps * 0.1);
    expect(Math.abs(tenThousand.nodes - thousand.nodes)).toBeLessThanOrEqual(thousand.nodes * 0.1);
  }, 120_000);

  test(`${list.name}: one call's change draws it alone, and a scroll by one view draws no step it keeps`, async () => {
    const acpmuxPerf = await perf();
    await fresh();
    const items = list.items(1_000);
    // A copy, as the transcript hands each draw its own snapshot: `items` changes in place below.
    await draw(list.node([...items]));
    await list.open?.();
    acpmuxPerf.enabled = true;
    try {
      // One mounted call changes (direct.ts replaces only its activity).
      acpmuxPerf.resetRenders();
      items[1] = list.change(items[1]!, 1);
      await draw(list.node([...items]));
      const changed = await counted();
      console.log(`${list.name}: commits on one change ${[...changed.commits.keys()].join(",")}`);
      expect([...changed.commits.keys()]).toEqual([items[1]!.tool!.id]);
      expect(changed.mounts.size).toBe(0);
      if (!list.box) return;
      // A scroll by one view: the steps that stay mounted draw nothing; only the ones it brings in mount.
      const before = new Set(
        [...host.querySelectorAll<HTMLElement>("[data-step-call]")].map((step) => step.dataset.stepCall!),
      );
      acpmuxPerf.resetRenders();
      await scrollBox(list.view);
      const scrolled = await counted();
      const kept = [...scrolled.commits.keys()].filter((id) => before.has(id) && !scrolled.mounts.has(id));
      console.log(`${list.name}: scroll by one view: ${kept.length} kept steps drawn, ${scrolled.mounts.size} mounted`);
      expect(kept).toEqual([]);
      expect(scrolled.mounts.size).toBeGreaterThan(0);
      expect(scrolled.mounts.size).toBeLessThanOrEqual(Math.ceil(list.view / STEP) + 1);
    } finally {
      acpmuxPerf.enabled = false;
      acpmuxPerf.resetRenders();
    }
  }, 120_000);
}

test("a windowed group keeps its height: the boxes and drawn steps add up to every step's", async () => {
  await fresh();
  await draw(<Group items={commands(1_000)} />);
  const list = host.querySelector<HTMLElement>(".cv-steps")!;
  const rests = [...list.querySelectorAll<HTMLElement>(":scope > [data-steps-rest]")];
  const covered = rests.reduce((sum, rest) => sum + Number(rest.dataset.stepsRest), 0);
  const height = rests.reduce((sum, rest) => sum + parseFloat(rest.style.height), 0);
  expect(covered + list.querySelectorAll(":scope > .cv-step").length).toBe(1_000);
  expect(height).toBe(covered * STEP);
});

test("a selection from step 2 past the window copies every step between its ends in order, and the list windows again once cleared", async () => {
  await fresh();
  await draw(<Group items={commands(1_000)} />);
  const list = host.querySelector<HTMLElement>(".cv-steps")!;
  const step = (n: number) => list.querySelector<HTMLElement>(`[data-step-call="cmd-${n}"]`);
  /// The text node that draws `echo n` in step n.
  const words = (n: number) => {
    const walker = document.createTreeWalker(step(n)!, window.NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode())
      if (node.textContent?.includes(`echo ${n}`)) return node;
    throw new Error(`no text for step ${n}`);
  };
  const select = async (from: Node, to: Node) => {
    const range = document.createRange();
    range.setStart(from, 0);
    range.setEnd(to, to.textContent!.length);
    const selection = document.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);
    await act(async () => document.dispatchEvent(new window.Event("selectionchange")));
  };
  const windowed = list.querySelectorAll(":scope > .cv-step").length;
  // The reader presses on step 2 and drags down: the box scrolls to step 600, which draws there.
  await select(words(2), words(3));
  await scrollBox(600 * STEP);
  expect(step(2)).not.toBeNull();
  expect(step(600)).not.toBeNull();
  await select(words(2), words(600));
  // Every step between the ends is drawn, so the copy holds each one's text, in order.
  const copied = document.getSelection()!.toString();
  let from = 0;
  for (let n = 2; n <= 600; n++) {
    const at = copied.indexOf(`echo ${n}`, from);
    expect({ n, found: at >= 0 }).toEqual({ n, found: true });
    from = at + 1;
  }
  expect(list.querySelectorAll(":scope > .cv-step").length).toBeGreaterThanOrEqual(599);
  // Cleared: back to the view's window.
  document.getSelection()!.removeAllRanges();
  await act(async () => document.dispatchEvent(new window.Event("selectionchange")));
  expect(list.querySelectorAll(":scope > .cv-step").length).toBeLessThanOrEqual(most(BOX));
  expect(list.querySelectorAll(":scope > .cv-step").length).toBeGreaterThanOrEqual(windowed - 1);
});
