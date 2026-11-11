// l10n-allow-file: test fixture commands and messages, not shipped UI.
// A received agent message that the agent reads mid-turn joins the run above it in a message run
// line, and that line stays the run's row on screen: no unmount, no new frame, no entrance (Leo,
// 2026-11-07: "I just saw that the tool call of this thing that got sent in, that came in, flickered
// a bit"). While the turn runs nothing folds (cmux#38339): the run and the message keep their rows
// until the turn ends, which folds them under the line.
//
// Before: the line was a new row keyed `messageRun-<run id>`, so the run's frame unmounted and a new
// one mounted and played the live entrance. After: the line is drawn in its first row's frame
// (`AcpmuxRow.frame`), so the same article goes from the run's line to the message run's line in one
// commit; the line's id, its fold key, Find and the open state are as they were.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

// This file covers the `runs` arm of liveTurnWork.experiment.ts: a running turn keeps its finished
// runs in sight until it ends. The shipped `line` arm (one live line, as chatgpt.com draws a running
// turn) is covered by live-turn-one-line.test.ts.
const liveTurnArmsBefore = globalThis.cmuxExperiments;
beforeAll(() => {
  globalThis.cmuxExperiments = { ...liveTurnArmsBefore, "live-turn-work": "runs" };
});
afterAll(() => {
  globalThis.cmuxExperiments = liveTurnArmsBefore;
});

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
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

let n = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: fields.id ?? `${kind}-${(n += 1)}`,
  version: 1,
  at: (n += 1) * 1000,
  kind,
  ...fields,
});
const run = (command: string): AcpmuxActivity => ({
  kind: "tool",
  text: command,
  tool: { id: `tool-${(n += 1)}`, title: command, kind: "execute", status: "completed", command, output: "ok\n" },
});
const prompt = row("user", { id: "prompt", text: "Look around" });
const calls = row("activity", { id: "activity-1", items: [run("ls"), run("pwd")], toolCount: 2 });
/// Another agent's message steered into the running turn: waiting until the agent reads it.
const message = (steer?: "waiting") =>
  row("user", {
    id: "steer-1",
    at: 9_000,
    text: "",
    continues: true,
    ...(steer && { steer }),
    incoming: { kind: "message", message: { name: "lane-2", sessionId: "lane-2", text: "hi", raw: "hi" } },
  });
const live = (expanded: Set<string>, steer?: "waiting") =>
  turnView([prompt, calls, message(steer)], expanded, { agentFamily: "claude", working: true });
const reply = row("assistant", { id: "reply", text: "Done looking around." });
const summary = row("turnSummary", { id: "summary", status: "completed", durationMs: 5_000 });
/// The turn ended: the run and the message it read fold under one line.
const ended = (expanded: Set<string>) =>
  turnView([prompt, calls, message(), reply, summary], expanded, { agentFamily: "claude" });

for (const fold of [undefined, "runs"] as const)
  test(`the run's line keeps its frame when the turn's end folds a steered message the agent read (claude-turn-fold ${fold ?? "default"})`, async () => {
    globalThis.cmuxExperiments = { "live-turn-work": "runs", ...(fold ? { "claude-turn-fold": fold } : {}) };
    const host = dom.window.document.createElement("div");
    dom.window.document.body.append(host);
    const root = createRoot(host);
    let expanded = new Set<string>();
    const render = (rows: AcpmuxRow[]) =>
      act(async () => {
        root.render(
          <VirtualTranscript
            rows={rows}
            registry={defaultRegistry}
            sessionId={`message-run-frame-${fold ?? "default"}`}
            onToggleActivity={() => {}}
            expanded={expanded}
          />,
        );
        await new Promise((resolve) => setTimeout(resolve, 0));
      });
    try {
      await render([prompt]);
      // The run arrives live, then another agent's message waits for the agent to read it.
      await render(live(expanded));
      await render(live(expanded, "waiting"));
      const before = host.querySelector<HTMLElement>('[data-row-id="activity-1"]');
      expect(before?.querySelector(".cv-tool")).toBeTruthy();
      const entered = before!.classList.contains("acpmux-row--enter");
      const removed: Node[] = [];
      const watch = new dom.window.MutationObserver((records) => {
        for (const record of records) removed.push(...record.removedNodes);
      });
      watch.observe(before!.parentElement!, { childList: true });
      // The agent reads it: the turn still runs, so the run and the message keep their own rows.
      const read = live(expanded);
      expect(read.some((item) => item.kind === "messageRun")).toBe(false);
      await render(read);
      expect(host.querySelector('[data-row-id="activity-1"]') === before).toBe(true);
      // The turn ends: the run and the message fold under one line. Under the default fold the line
      // is in the turn's "Worked for", held open as the turn's end holds the work in view
      // (turnEndHold.ts); the per-run fold draws it in the turn.
      const work = fold ? [] : ["worked-prompt"];
      expanded = new Set(work);
      const done = ended(expanded);
      const line = done.find((item) => item.kind === "messageRun")!;
      expect(line.id).toBe("messageRun-activity-1");
      await render(done);
      watch.takeRecords().forEach((record) => removed.push(...record.removedNodes));
      watch.disconnect();
      const after = host.querySelector<HTMLElement>("[data-message-run]")?.closest("article");
      // Compared as a boolean: a failing DOM node prints the whole jsdom window.
      expect(after === before).toBe(true);
      expect(removed.includes(before!)).toBe(false);
      expect(after!.dataset.rowId).toBe("messageRun-activity-1");
      // The entrance the run played when it arrived is not played again: the class is the one the
      // frame mounted with, on the same element, so no animation restarts.
      expect(after!.classList.contains("acpmux-row--enter")).toBe(entered);

      // Opening the line draws its rows under it, keeps the line's own frame, and the open run's
      // first row (the run's own id) draws in a frame of its own.
      expanded = new Set([...work, line.id]);
      await render(ended(expanded));
      const open = host.querySelector<HTMLElement>("[data-message-run]")?.closest("article");
      expect(open === before).toBe(true);
      expect(open!.querySelector("[data-message-run]")?.getAttribute("aria-expanded")).toBe("true");
      const member = host.querySelector<HTMLElement>('[data-row-id="activity-1"]');
      expect(member).toBeTruthy();
      expect(member === before).toBe(false);
      // Closed again, the line is still that frame.
      expanded = new Set(work);
      await render(ended(expanded));
      expect(host.querySelector<HTMLElement>("[data-message-run]")?.closest("article") === before).toBe(true);
    } finally {
      await act(async () => root.unmount());
      host.remove();
      globalThis.cmuxExperiments = { "live-turn-work": "runs" };
    }
  });
