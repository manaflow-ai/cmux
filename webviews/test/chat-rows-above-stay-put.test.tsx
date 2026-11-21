// l10n-allow-file: test fixture commands and messages, not shipped UI.
// Rows above the newest message neither remount nor draw their content again while only the latest
// turn changes: a prompt sent, a tool call finishing, a reply streaming, the turn ending (Leo,
// 2026-11-21: "sometimes the messages above the most recent message seem to wholly rerender").
// A received agent message that the agent reads mid-turn joins the run above it in a message run
// line, and that line stays the run's row on screen: no unmount, no new frame, no entrance (Leo,
// 2026-11-07: "I just saw that the tool call of this thing that got sent in, that came in, flickered
// a bit"). The running turn folds them as the ended one does (Lucas, 2026-11-11, taking back
// cmux#38339's "nothing folds while the turn runs").
//
// Before: the line was a new row keyed `messageRun-<run id>`, so the run's frame unmounted and a new
// one mounted and played the live entrance. After: the line is drawn in its first row's frame
// (`AcpmuxRow.frame`), so the same article goes from the run's line to the message run's line in one
// commit; the line's id, its fold key, Find and the open state are as they were.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { TurnView } from "../src/agent-session/acpmux/conversation/turns";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  Range: dom.window.Range,
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
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|CustomEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { defaultRegistry } = await import("../src/agent-session/acpmux/rows/registry");
const { turnViewFrom } = await import("../src/agent-session/acpmux/conversation/turns");
const { projectInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const { acpmuxPerf } = await import("../src/agent-session/acpmux/perf");

const MODES = [
  { name: "same row objects", copy: false, chain: false },
  { name: "a snapshot that clones unchanged rows", copy: true, chain: false },
  // The pane's own path: each snapshot's view is built on the last (App.tsx turnViewFrom).
  { name: "views built on the last view", copy: false, chain: true },
  { name: "views built on the last view, rows cloned", copy: true, chain: true },
] as const;

let n = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: fields.id ?? `${kind}-${(n += 1)}`,
  version: 1,
  at: (n += 1) * 1000,
  kind,
  ...fields,
});
const tool = (id: string, status: "running" | "completed") => ({
  kind: "tool" as const,
  text: "ls",
  tool: { id, title: "ls", kind: "execute", status, command: "ls", output: status === "completed" ? "ok\n" : "" },
});
/// One finished turn: prompt, a run, a reply, its footer.
const finished = (turn: number): AcpmuxRow[] => [
  row("user", { id: `prompt-${turn}`, text: `Question ${turn}` }),
  row("activity", { id: `activity-${turn}`, items: [tool(`tool-${turn}`, "completed")], toolCount: 1 }),
  row("assistant", { id: `reply-${turn}`, text: `Answer ${turn}, with some words in it.` }),
  row("turnSummary", { id: `summary-${turn}`, status: "completed", durationMs: 5_000 }),
];
/// Another agent's message the agent read mid-turn (a line in the turn, as message-run-keeps-frame).
const received = (id: string, text: string): AcpmuxRow =>
  row("user", {
    id,
    text: "",
    continues: true,
    incoming: { kind: "message", message: { name: "lane-2", sessionId: "lane-2", text, raw: text } },
  });
const plain = [...finished(1), ...finished(2), ...finished(3)];
/// The same chat with received messages in the turns above, two in a row among them (they draw as
/// one "Received 2 messages" row, which the display projection rebuilds when a message comes).
const withMessages = [
  ...finished(1),
  ...finished(2).flatMap((item) =>
    item.id === "activity-2" ? [item, received("received-2a", "first"), received("received-2b", "second")] : [item],
  ),
  ...finished(3).flatMap((item) => (item.id === "activity-3" ? [item, received("received-3a", "third")] : [item])),
];
const SCENARIOS = [
  { name: "a chat of plain turns", history: plain, arrives: false },
  { name: "a chat with received messages above", history: withMessages, arrives: true },
] as const;

for (const scenario of SCENARIOS)
  for (const mode of MODES)
    test(`rows above the newest message stay as they are while only the latest turn changes: ${scenario.name}, ${mode.name}`, async () => {
      const history = scenario.history;
      const host = dom.window.document.createElement("div");
      dom.window.document.body.append(host);
      const root = createRoot(host);
      const folds = new Set<string>();
      let previous: TurnView | undefined;
      let shownBefore: readonly AcpmuxRow[] | undefined;
      /// Every row the finished turns drew, read once they are on screen.
      let ABOVE: string[] = [];
      const render = (source: AcpmuxRow[], working: boolean) =>
        act(async () => {
          const sent = mode.copy ? source.map((item) => ({ ...item })) : source;
          const view = turnViewFrom(sent, folds, { agentFamily: "claude", working }, mode.chain ? previous : undefined);
          const shown = projectInboxRows(view.rows, mode.chain ? shownBefore : undefined, view.reusedRows);
          previous = view;
          shownBefore = view.rows;
          root.render(
            <VirtualTranscript
              rows={shown as AcpmuxRow[]}
              streams
              registry={defaultRegistry}
              sessionId={`rows-above-${mode.name}`}
              onToggleActivity={() => {}}
              expanded={folds}
            />,
          );
          await new Promise((resolve) => setTimeout(resolve, 0));
        });
      const articles = () => {
        const found = new Map<string, Element>();
        for (const id of ABOVE) {
          const node = host.querySelector(`[data-row-id="${id}"]`);
          if (node) found.set(id, node);
        }
        return found;
      };
      /// What the step moved among the rows above: content drawn again, frames replaced.
      const steps: string[] = [];
      let held = new Map<string, Element>();
      const step = async (name: string, source: AcpmuxRow[], working: boolean) => {
        held = articles();
        acpmuxPerf.resetRenders();
        await render(source, working);
        // The one change a new prompt makes above it is real: the turn before it stops offering Retry
        // (`retryTarget`), so that footer draws again, without its button. Nothing else above does.
        const drawn = ABOVE.filter(
          (id) => (acpmuxPerf.renders.get(`content:${id}`) ?? 0) > 0 && !(name === "prompt sent" && id === "summary-3"),
        );
        const now = articles();
        const replaced = ABOVE.filter((id) => held.get(id) !== now.get(id));
        if (drawn.length || replaced.length)
          steps.push(`${name}: content drawn again [${drawn.join(", ")}], frames replaced [${replaced.join(", ")}]`);
      };
      const was = acpmuxPerf.enabled;
      try {
        acpmuxPerf.enabled = true;
        await render(history, false);
        ABOVE = [...host.querySelectorAll<HTMLElement>("[data-row-id]")].map((node) => node.dataset.rowId!);
        expect(ABOVE.length).toBeGreaterThan(10);
        // (a) a new prompt is sent, and the turn starts.
        const prompt = row("user", { id: "prompt-4", text: "Question 4" });
        await step("prompt sent", [...history, prompt], true);
        // (b) a tool call in the latest turn runs, then completes.
        const running = row("activity", { id: "activity-4", items: [tool("tool-4", "running")], toolCount: 1 });
        // Another agent's message reaches the turn too, where the scenario has any above.
        const arrived = scenario.arrives ? [received("received-4", "now")] : [];
        await step("tool call starts", [...history, prompt, running, ...arrived], true);
        const done = { ...running, version: 2, items: [tool("tool-4", "completed")] };
        await step("tool call completes", [...history, prompt, done, ...arrived], true);
        // (d) a streamed delta into the latest reply.
        const reply = row("assistant", { id: "reply-4", text: "Streaming", streaming: true });
        await step("reply starts", [...history, prompt, done, ...arrived, reply], true);
        const longer = { ...reply, version: 2, text: "Streaming a longer answer" };
        await step("reply delta", [...history, prompt, done, ...arrived, longer], true);
        // (c) the turn ends: the live line goes and the footer comes.
        const final = { ...longer, version: 3, streaming: false };
        const summary = row("turnSummary", { id: "summary-4", status: "completed", durationMs: 4_000 });
        await step("turn ends", [...history, prompt, done, ...arrived, final, summary], false);
      } finally {
        acpmuxPerf.enabled = was;
        await act(async () => root.unmount());
        host.remove();
      }
      expect(steps).toEqual([]);
    });
