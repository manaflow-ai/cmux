// l10n-allow-file: test fixtures, not shipped UI.
// No "Worked for" row is ever drawn over a reply (cmux#59809, "how did this regress again"). The shape is
// the reporter's chat: a background task's finish woke the agent (a background turn: its calls, its reply,
// its footer), and a subagent the person's turn had started ended after that footer. The running tray tags
// a subagent's end line with the background turn that was running when it ended, so the line belongs to
// a background turn whose fold was already drawn. Since cmux#56185 gave a quick turn of subagents alone its
// own "Worked for", that line was shaped as the turn again: a second `worked-backgroundTurn-…` row with the
// first one's id, two transcript rows under one React key, and React left one of them painted where it
// had been placed, across a bullet of the reply below (the reporter's screenshot).
// cmux#61614 draws such a late row in place under the fold; this test keeps it drawn once.
//
// The transcript draws the rows as the live pane gets them: first the background turn alone, then the
// subagent's end and the next turn after it. Every "Worked for" drawn is its own row, every row is drawn
// once, and no "Worked for" box crosses a reply's box, read from where the transcript placed each row.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
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
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout. A tall viewport mounts every row of this small chat.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView, WORKED } = await import("../src/agent-session/acpmux/conversation/turns");
const { BACKGROUND_TURN, backgroundTurnRowId } = await import("../src/agent-session/acpmux/conversation/backgroundTurns");
type AcpmuxRow = import("../src/agent-session/acpmux/model").AcpmuxRow;

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const BUILD = "bg-done-bg-build";
const REVIEW = "bg-review";
const woke = (id: string, at: number, seq: number): AcpmuxRow => ({
  id: backgroundTurnRowId(id),
  version: 1,
  at,
  seq,
  kind: BACKGROUND_TURN,
  background: {
    id,
    trigger: "task_notification",
    running: false,
    quiet: false,
    hasRows: true,
    reason: "result",
    cause: { kind: "shell", status: "completed", weight: "result", summary: "bgTask.completed" },
  },
});
const call = (id: string, at: number, inBackground?: string): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "activity",
  toolCount: 1,
  ...(inBackground && { inBackground }),
  items: [{ kind: "tool", text: "Read build log", tool: { id: `${id}-c`, title: "Read build log", kind: "execute", status: "completed" } }],
});

/// The person's turn, then the build's background turn, ended.
const before: AcpmuxRow[] = [
  { id: "user-1", version: 1, at: 1_000, kind: "user", text: "Launch the dev build" },
  call("activity-1", 1_100),
  { id: "assistant-1", version: 1, at: 1_200, kind: "assistant", text: "Submitted. A review subagent checks it." },
  { id: "summary-1", version: 1, at: 1_300, seq: 5, kind: "turnSummary", status: "completed", durationMs: 300, toolCount: 1 },
  woke(BUILD, 2_000, 6_909),
  call("activity-6922", 2_010, BUILD),
  {
    id: "assistant-6973",
    version: 1,
    at: 2_100,
    kind: "assistant",
    inBackground: BUILD,
    text: "Once the build lands, I'll replay both cases:\n\n- **Nightly as default browser:** the tab closes.\n- **Chrome as default:** the running build takes the link.",
  },
  {
    id: "summary-7020",
    version: 1,
    at: 2_110,
    seq: 7_020,
    kind: "turnSummary",
    status: "completed",
    durationMs: 7_410,
    toolCount: 1,
    inBackground: BUILD,
  },
];
/// What came after: the person's turn's subagent ended (its line tagged with the build's turn), then
/// the subagent's report woke the agent again.
const after: AcpmuxRow[] = [
  ...before,
  {
    id: "subagentDone:chat/toolu_review",
    version: 1,
    at: 3_000,
    kind: "subagentDone",
    inBackground: BUILD,
    subagentDone: { id: "toolu_review", name: "Review the change", status: "completed" },
  } as AcpmuxRow,
  woke(REVIEW, 3_100, 7_056),
  { id: "assistant-7090", version: 1, at: 3_200, kind: "assistant", inBackground: REVIEW, text: "The review passed." },
];

/// The placed band of each drawn row: its offset as the transcript wrote it and the height it gave it.
function bands(document: Document) {
  return [...document.querySelectorAll<HTMLElement>(".acpmux-row")].map((node) => {
    const top = Number.parseFloat(node.style.top) + (Number.parseFloat(node.style.marginTop) || 0);
    const height = Number.parseFloat(node.style.height) || Number.parseFloat(node.style.minHeight) || 1;
    return { id: node.dataset.rowId ?? "", node, top, bottom: top + height };
  });
}

test("the turn view draws one Worked for per background turn, and a subagent's end after its footer in place", () => {
  for (const agentFamily of ["claude", "codex", undefined]) {
    const rows = turnView(after, new Set(), { now: 10_000, agentFamily });
    const ids = rows.map((row) => row.id);
    expect(ids.filter((id, index) => ids.indexOf(id) !== index)).toEqual([]);
    expect(ids.filter((id) => id === `${WORKED}-${backgroundTurnRowId(BUILD)}`)).toHaveLength(1);
    // The subagent's end draws as it came: after the build turn's footer, before the next wake's reply.
    const done = ids.indexOf("subagentDone:chat/toolu_review");
    expect(done).toBeGreaterThan(ids.indexOf("summary-7020"));
    expect(done).toBeLessThan(ids.indexOf("assistant-7090"));
  }
});

test("no Worked for row is drawn over a reply when a subagent ends after a background turn's footer", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  try {
    for (const source of [before, after]) {
      const rows = turnView(source, expanded, { now: 10_000, agentFamily: "claude" });
      await act(async () =>
        root.render(<VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={expanded} />),
      );
      const document = dom.window.document;
      const drawn = bands(document);
      // Every row is drawn once: a row two elements claim is the stale copy React left behind.
      const ids = drawn.map((band) => band.id);
      expect(ids.filter((id, index) => ids.indexOf(id) !== index)).toEqual([]);
      // Every "Worked for" drawn is a row of the view, inside the row the transcript placed for it.
      const worked = [...document.querySelectorAll(".cv-worked")];
      expect(worked.length).toBe(rows.filter((row) => row.kind === WORKED).length);
      for (const line of worked) expect(line.closest(".acpmux-row[data-row-id]")).not.toBeNull();
      // No "Worked for" row's band crosses a reply's band.
      const replies = drawn.filter((band) => band.node.querySelector(".cv-message, .acpmux-assistant") || band.id.startsWith("assistant-"));
      for (const line of drawn.filter((band) => band.node.querySelector(".cv-worked")))
        for (const reply of replies)
          expect({ line: line.id, reply: reply.id, crosses: line.top < reply.bottom && reply.top < line.bottom }).toEqual({
            line: line.id,
            reply: reply.id,
            crosses: false,
          });
    }
  } finally {
    await act(async () => root.unmount());
  }
});
