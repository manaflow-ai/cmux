// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// A closed turn fold hides tool and work rows only, never a reply to the person, wherever it sits in
// the turn: at its start, between two tool groups, after a background task's notice, before another
// agent's inbox notice (Leo, 2026-11-06, on a closed "Worked for 2m 22s" that hid his answer: "your
// intermediate message got lost. that can never happen", then "those intermediate messages should be
// counted differently than other tool calls like it's a special never-fold type"). The work around
// each reply stays under Worked for, as chatgpt.com draws it (turn-fold-hides-every-call.test.ts), and
// no count reads a reply as a call.
// Gallery: agent-pane.turn-fold-replies.
import { afterEach, expect, test } from "bun:test";
import { MESSAGE_RUN, type AcpmuxActivity, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { incomingPrompt } from "../src/agent-session/acpmux/conversation/incomingMessage";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 6, 21, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const calls = (id: string, second: number, count: number): AcpmuxRow =>
  row(id, "activity", second, {
    items: Array.from({ length: count }, (_, index): AcpmuxActivity => ({
      kind: "tool",
      text: "",
      tool: {
        id: `${id}-${index}`,
        title: `git status ${index}`,
        kind: "execute",
        status: "completed",
        command: `git status ${index}`,
      },
    })),
  });

const REPLIES = {
  start:
    "Right. The command-line test comes first:\n\n- A clicking test drives the current nightly.\n- The Cloud UI moves to React.",
  middle:
    "No, they aren't treated normally. Each Cloud machine gets its own group.\n\n- A Cloud workspace goes into its machine's group.\n- There's no automatic group.",
  afterNotice: "The background build passed, so the group change is safe to land.\n\nI'll send it now.",
  final: "I'm running two helpers in the background:\n\n- Every basic Cloud step.\n- Every piece of Swift UI.",
};

const INBOX = "[inbox] New messages from other agents in 1 thread.\n- 1 new in #101 from fs-lane-1: Ready.";

/// One finished turn: a reply at its start, a reply between two tool groups, a reply after a
/// background task's notice, and the final answer after another agent's inbox notice.
const turn: AcpmuxRow[] = [
  row("u-0", "user", 0, { text: "Are Cloud workspaces grouped like the others?" }),
  row("a-start", "assistant", 2, { text: REPLIES.start }),
  calls("t-1", 3, 3),
  row("a-middle", "assistant", 20, { text: REPLIES.middle }),
  calls("t-2", 21, 4),
  row("n-1", "user", 60, {
    text: "Background command finished",
    continues: true,
    incoming: { kind: "notice", text: "Background command finished" },
  } as Partial<AcpmuxRow>),
  row("a-notice", "assistant", 62, { text: REPLIES.afterNotice }),
  calls("t-3", 63, 1),
  row("i-1", "user", 100, {
    text: INBOX,
    continues: true,
    incoming: incomingPrompt(INBOX, {
      _meta: {
        provenance: {
          kind: "inbox_notice",
          threads: [
            {
              threadId: "from:fs-lane-1/pr:101",
              label: "#101",
              new: 1,
              from: ["fs-lane-1"],
              promptIds: ["i-1-prompt"],
              preview: "Ready.",
            },
          ],
        },
      },
    }) as AcpmuxRow["incoming"],
  }),
  row("a-final", "assistant", 130, { text: REPLIES.final }),
  row("s-0", "turnSummary", 142, { status: "completed", durationMs: 142_000, toolCount: 8 }),
];
const REPLY_IDS = ["a-start", "a-middle", "a-notice", "a-final"];

const FAMILIES = ["claude", "codex", "gemini", "muse", undefined];
const closed = (agentFamily: string | undefined, rows = turn) =>
  turnView(rows, new Set(), { agentFamily, now: START + 200_000 });

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

/// The rows of `view` that draw a reply or a run of calls, in order: a reply by its id, a run as
/// "run:<its calls>". A run folded with the notice or message beside it (messageRuns.ts) counts its
/// calls too: the notice stays in sight with the work around it.
const outline = (view: AcpmuxRow[]) =>
  view.flatMap((shown) =>
    shown.kind === "assistant"
      ? [shown.id]
      : shown.kind === "activity"
        ? [`run:${(shown.items ?? []).filter((item) => item.tool).length}`]
        : shown.kind === MESSAGE_RUN
          ? [`run:${(shown.messageRun?.work ?? []).filter((item) => item.tool).length}`]
          : [],
  );

for (const family of FAMILIES)
  test(`${family ?? "an unknown family"}: a closed fold keeps every reply in place and the work around each under it`, () => {
    const view = closed(family);
    const worked = view.find((shown) => shown.kind === WORKED);
    expect(worked).toBeDefined();
    expect(worked!.foldOpen).toBe(false);
    // Every reply, the one between two tool groups included, draws, in the order it was said, with
    // its own words; the work before and after each stays under Worked for.
    expect(outline(view)).toEqual(["a-start", "a-middle", "a-notice", "a-final"]);
    for (const id of REPLY_IDS)
      expect(view.find((shown) => shown.id === id)?.text).toBe(turn.find((r) => r.id === id)!.text);
    // The line sits over the turn's first reply.
    expect(view.indexOf(worked!)).toBeLessThan(view.findIndex((shown) => shown.id === "a-start"));
  });

test("no count reads a reply as a call: the fold's lines count calls, the header counts no reply", () => {
  // The lines beside a closed fold draw only in the arms that keep them (the default keeps none).
  globalThis.cmuxExperiments = { "turn-fold-replies": "groups" };
  for (const family of FAMILIES) {
    const view = closed(family);
    // A run folded with the notice beside it (messageRuns.ts) counts its calls as the run would.
    const runs = view.flatMap((shown) =>
      shown.kind === "activity" ? [shown.items ?? []] : shown.kind === MESSAGE_RUN ? [shown.messageRun!.work] : [],
    );
    for (const items of runs) expect(items.every((item) => item.tool || item.kind === "note")).toBe(true);
    expect(runs.reduce((n, items) => n + items.filter((item) => item.tool).length, 0)).toBe(8);
    // The header's "N previous messages" counts what the fold hides; every reply is in sight, so it
    // reads "Worked for".
    expect(view.find((shown) => shown.kind === WORKED)!.previous).toBeUndefined();
  }
});

test("a reply between two tool groups shows folded, and opening the fold keeps it where it was", () => {
  const between: AcpmuxRow[] = [
    row("u-0", "user", 0, { text: "Group them" }),
    calls("t-1", 1, 2),
    row("a-middle", "assistant", 20, { text: REPLIES.middle }),
    calls("t-2", 21, 4),
    row("a-final", "assistant", 40, { text: REPLIES.final }),
    row("s-0", "turnSummary", 41, { status: "completed", durationMs: 41_000, toolCount: 6 }),
  ];
  for (const family of FAMILIES) {
    expect(outline(closed(family, between))).toEqual(["a-middle", "a-final"]);
    const opened = turnView(between, new Set([`${WORKED}-u-0`]), { agentFamily: family, now: START + 60_000 });
    const order = outline(opened);
    expect(order.indexOf("a-middle")).toBeGreaterThan(0);
    expect(order.indexOf("a-middle")).toBeLessThan(order.indexOf("a-final"));
  }
});

test("a turn with no reply before its answer folds as before: one line, the answer under it", () => {
  const plain: AcpmuxRow[] = [
    row("u-0", "user", 0, { text: "Check it" }),
    calls("t-1", 1, 2),
    row("note", "assistant", 5, { text: "Checking the log next." }),
    calls("t-2", 6, 3),
    row("a-final", "assistant", 40, { text: REPLIES.final }),
    row("s-0", "turnSummary", 41, { status: "completed", durationMs: 41_000, toolCount: 5 }),
  ];
  for (const family of FAMILIES) expect(outline(closed(family, plain))).toEqual(["a-final"]);
});

test("each arm keeps every reply; they differ only in the work between replies", () => {
  const arms: Record<string, string[]> = {
    groups: ["a-start", "run:3", "a-middle", "run:4", "a-notice", "run:1", "a-final"],
    replies: ["a-start", "a-middle", "a-notice", "a-final"],
  };
  for (const [arm, expected] of Object.entries(arms)) {
    globalThis.cmuxExperiments = { "turn-fold-replies": arm };
    expect(outline(closed("claude"))).toEqual(expected);
  }
  globalThis.cmuxExperiments = { "turn-fold-replies": "runs" };
  const runs = outline(closed("claude"));
  for (const id of REPLY_IDS) expect(runs).toContain(id);
  expect(runs.filter((entry) => entry.startsWith("run:"))).toEqual(["run:3", "run:4", "run:1"]);
});

test("a running turn keeps the same replies in sight between its runs", () => {
  const running = turn.slice(0, -2);
  const view = turnView(running, new Set(), {
    working: true,
    agentFamily: "claude",
    now: START + 200_000,
  });
  const order = outline(view);
  for (const id of ["a-start", "a-middle", "a-notice"]) expect(order).toContain(id);
  expect(order.indexOf("a-start")).toBeLessThan(order.indexOf("a-middle"));
  expect(order.indexOf("a-middle")).toBeLessThan(order.indexOf("a-notice"));
});

test("a closed fold's line around a reply never shows a draft call as a finished one", () => {
  // A shell call that never got its command (toolGroups.ts isDraftCall) after the reply: the open
  // fold drops it, so the closed line must not read it as "Ran 1 command".
  const draft = row("t-draft", "activity", 25, {
    items: [{ kind: "tool", text: "", tool: { id: "draft-0", title: "Bash", kind: "execute", status: "in_progress" } }],
  });
  const rows: AcpmuxRow[] = [
    row("u-0", "user", 0, { text: "Group them" }),
    calls("t-1", 1, 2),
    row("a-middle", "assistant", 20, { text: REPLIES.middle }),
    draft,
    calls("t-2", 30, 3),
    row("a-final", "assistant", 40, { text: REPLIES.final }),
    row("s-0", "turnSummary", 41, { status: "completed", durationMs: 41_000, toolCount: 5 }),
  ];
  for (const arm of ["groups", "runs"]) {
    globalThis.cmuxExperiments = { "turn-fold-replies": arm };
    const view = closed("claude", rows);
    expect(outline(view)).toEqual(["run:2", "a-middle", "run:3", "a-final"]);
    const tools = view.flatMap((shown) => (shown.items ?? []).flatMap((item) => (item.tool ? [item.tool.id] : [])));
    expect(tools).not.toContain("draft-0");
  }
});

test("the runs arm splits the work after a reply where the open fold does, a draft call between them", () => {
  // A short note joins the runs on either side of it (mergeShortNotes); a draft-only row beside it still
  // ends a run there, as the opened fold draws it, so closing the fold never redraws its runs.
  const draft = row("t-draft", "activity", 27, {
    items: [{ kind: "tool", text: "", tool: { id: "draft-0", title: "Bash", kind: "execute", status: "in_progress" } }],
  });
  const rows: AcpmuxRow[] = [
    row("u-0", "user", 0, { text: "Group them" }),
    calls("t-1", 1, 1),
    row("a-middle", "assistant", 20, { text: REPLIES.middle }),
    calls("t-2", 21, 2),
    row("note", "assistant", 25, { text: "Checking the log next." }),
    draft,
    calls("t-3", 30, 3),
    row("a-final", "assistant", 40, { text: REPLIES.final }),
    row("s-0", "turnSummary", 41, { status: "completed", durationMs: 41_000, toolCount: 6 }),
  ];
  globalThis.cmuxExperiments = { "turn-fold-replies": "runs" };
  const opened = turnView(rows, new Set([`${WORKED}-u-0`]), { agentFamily: "claude", now: START + 60_000 });
  const after = (view: AcpmuxRow[]) => outline(view).slice(outline(view).indexOf("a-middle") + 1, -1);
  expect(after(closed("claude", rows))).toEqual(after(opened));
});
