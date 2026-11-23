// l10n-allow-file: test fixture text, not shipped UI.
// One fold rule for every turn (hq#18554 ask 4; Leo, 2026-11-22: "clearly there's still improper
// folds and stuff", "the notices/etc, they dont properly fold in when your turn ends"): once a turn
// has ended, its work (thinking, calls, sends) draws under that turn's one closed "Worked for",
// whatever started the turn (a person's prompt, a steer, a background task's end, a subagent's
// step, another agent's notice). Its line, reply and footer stay in sight.
//
// The four shapes are rows from the coordinator chat in Leo's screenshots (session 01a18a35), the
// texts replaced:
//   (a) a wake turn of one thought and a reply (a background turn with no cause);
//   (b) a wake turn a failed subagent step started (`weight: "failure"`, so its line heads it), with
//       a thought and a SendMessage, after a subagent's report;
//   (c) a steer carried into its own turn, a thought, a second steer landing in that turn, then work;
//   (d) a background task's end (bg-done) whose turn is a thought and a SendMessage, then a turn an
//       inbox notice started.
// Base drew (a), (b) and (d)'s work as loose rows beside their replies, under no Worked for
// (turns.ts `endedTail`); `foldTailTurns` shapes each ended wake turn as a prompt's turn.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { turnView } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const thought = (text: string) => ({ kind: "thought" as const, text });
const call = (id: string, title: string, kind = "other", status = "completed") => ({
  kind: "tool" as const,
  text: title,
  tool: { id, title, kind, status },
});
const activity = (id: string, items: NonNullable<AcpmuxRow["items"]>, inBackground?: string) =>
  row(id, "activity", {
    ...(inBackground && { inBackground }),
    toolCount: items.filter((item) => item.kind === "tool").length,
    items,
  });
const subagents = (id: string, name: string, state = "running") =>
  row(id, "subagents", {
    subagents: [{ id: `${id}-agent`, parent: null, name, task: name, state, startedAt: at, background: true }],
  } as Partial<AcpmuxRow>);
const summary = (id: string, extra: Partial<AcpmuxRow> = {}) =>
  row(id, "turnSummary", { status: "completed", durationMs: 30_000, seq: at, toolCount: 1, ...extra });
const line = (id: string, background: Record<string, unknown>) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    background: { id, running: false, hasRows: true, quiet: false, reason: "result", ...background },
  } as Partial<AcpmuxRow>);

const notice = (id: string, text: string) =>
  row(id, "user", {
    text,
    incoming: {
      kind: "inbox",
      notice: {
        threads: [
          {
            threadId: "topic:pr/1",
            label: "pr/1",
            from: ["glaeda-land"],
            count: 1,
            blocker: true,
            promptIds: [`${id}-prompt`],
          },
        ],
      },
    },
  } as Partial<AcpmuxRow>);

/// (a) and (b): a notice's turn, then two turns the agent ran on its own.
function wakes(): AcpmuxRow[] {
  at = 0;
  return [
    notice("notice-1", "[notice from glaeda-land] glaeda land: the PR merged"),
    subagents("subagents-1", "Hold release lane"),
    row("reply-1", "assistant", { text: "The hold is gone in code, but neither PR has merged yet." }),
    summary("summary-1"),
    // (a) A wake with no cause: one thought, then its reply; the turn ended on no row of its own.
    line("bg-a", { trigger: "system" }),
    subagents("subagents-a", "Previews and favicon globes"),
    activity("thought-a", [thought("I've already asked about the header summary.")], "bg-a"),
    row("reply-a", "assistant", { text: "The header summary fix is in review.", inBackground: "bg-a" }),
    // (b) A subagent's report, then a wake a failed subagent step started.
    subagents("subagents-b", "Runner pool spot + right-size", "completed"),
    line("bg-b", {
      trigger: "task_notification",
      cause: { kind: "subagent_step", status: "failed", weight: "failure", summary: "sed -n 480,490p src/lib.rs" },
    }),
    activity("send-b", [thought("The cost after the change looks high."), call("send-b-0", "SendMessage")], "bg-b"),
    row("reply-b", "assistant", { text: "The runner pool fix hasn't merged yet.", inBackground: "bg-b" }),
    summary("summary-b", { inBackground: "bg-b" }),
  ];
}

/// (d): a person's turn, a background task's end with a thought and a send, then a notice's turn.
function bgDone(): AcpmuxRow[] {
  at = 0;
  return [
    row("prompt-d", "user", { text: "when did we decide to omit the icon" }),
    subagents("subagents-d", "Icon audit"),
    row("reply-d", "assistant", { text: "I've given this to the helper auditing icons." }),
    summary("summary-d"),
    line("bg-done-bg-1", {
      trigger: "task_notification",
      cause: { kind: "shell", status: "completed", weight: "result", summary: "bgTask.completed" },
    }),
    activity("send-d", [thought("Checks on the PR are failing."), call("send-d-0", "SendMessage")], "bg-done-bg-1"),
    row("reply-bg", "assistant", {
      text: "I sent both PRs to the helper that owns them.",
      inBackground: "bg-done-bg-1",
    }),
    summary("summary-bg", { toolCount: 2, inBackground: "bg-done-bg-1" }),
    notice("notice-d", "[notice from glaeda-land] glaeda land: stopped, head moved"),
    subagents("subagents-n", "Browser tabs never re-render"),
    activity("thought-n", [thought("I'm still not sure who owns it.")]),
    row("reply-n", "assistant", { text: "Nothing new for you." }),
    summary("summary-n", { toolCount: 0 }),
  ];
}

/// (c): a steer carried into its own turn, a thought, then a second steer that lands in that turn.
function steered(): AcpmuxRow[] {
  at = 0;
  return [
    row("prompt-c", "user", { text: "clearly there's still improper folds and stuff" }),
    activity("work-c", [thought("Three loose folds."), call("work-c-0", "SendMessage")]),
    row("reply-c", "assistant", { text: "I see three loose folds in your screenshot." }),
    summary("summary-c"),
    // Sent while that turn ran; the harness carried it into the next turn.
    row("steer-1", "user", { text: "you guys also need to be testing flicks of fast input" }),
    subagents("subagents-c1", "Attachments instant from disk"),
    activity("thought-c", [thought("I'm thinking about which helper to route this to.")]),
    row("steer-2", "user", {
      text: "the make cmux yours UI we need to hill climb",
      steer: "landed",
    } as Partial<AcpmuxRow>),
    subagents("subagents-c2", "Power-user input stress harness"),
    activity("work-c2", [
      thought("Make cmux yours is the welcome card."),
      call("work-c2-0", "rg welcome", "execute", "failed"),
    ]),
    row("reply-c2", "assistant", { text: "I started two helpers for your last two messages." }),
    summary("summary-c2"),
  ];
}

const ids = (rows: readonly AcpmuxRow[]) => rows.map((entry) => entry.id);
/// The work rows a finished turn draws loose: a thought or a call, as itself or in a run's line.
const looseWork = (rows: readonly AcpmuxRow[]) =>
  rows.filter((entry) => entry.kind === "activity" || entry.kind === "messageRun").map((entry) => entry.id);

for (const agentFamily of ["claude", "codex", undefined]) {
  const family = agentFamily ?? "default";

  test(`${family}: (a) and (b) each wake turn's thought and send fold under its one closed Worked for`, () => {
    const view = turnView(wakes(), new Set(), { now: 120_000, agentFamily });
    expect(looseWork(view)).toEqual([]);
    for (const background of ["bg-a", "bg-b"]) {
      const worked = view.filter((entry) => entry.id === `worked-${backgroundTurnRowId(background)}`);
      expect(worked).toHaveLength(1);
      expect(worked[0]).toMatchObject({ kind: "worked", foldOpen: false });
    }
    // The replies stay in sight, each under its own fold; (b)'s line keeps heading its turn.
    const drawn = ids(view);
    expect(drawn.indexOf("reply-a")).toBeGreaterThan(drawn.indexOf(`worked-${backgroundTurnRowId("bg-a")}`));
    expect(drawn.indexOf("reply-b")).toBeGreaterThan(drawn.indexOf(`worked-${backgroundTurnRowId("bg-b")}`));
    expect(drawn.indexOf(backgroundTurnRowId("bg-b"))).toBeLessThan(
      drawn.indexOf(`worked-${backgroundTurnRowId("bg-b")}`),
    );
  });

  test(`${family}: (d) a background task's end and the notice's turn after it both fold their work`, () => {
    const view = turnView(bgDone(), new Set(), { now: 120_000, agentFamily });
    expect(looseWork(view)).toEqual([]);
    expect(view.find((entry) => entry.id === `worked-${backgroundTurnRowId("bg-done-bg-1")}`)).toMatchObject({
      kind: "worked",
      foldOpen: false,
    });
    const drawn = ids(view);
    for (const id of ["reply-d", "reply-bg", "summary-bg", "reply-n", "summary-n"]) expect(drawn).toContain(id);
  });

  test(`${family}: (c) a carried steer's thought folds under its Worked for once the turn ends`, () => {
    const view = turnView(steered(), new Set(), { now: 120_000, agentFamily });
    expect(looseWork(view)).toEqual([]);
    const drawn = ids(view);
    for (const id of ["prompt-c", "steer-1", "steer-2", "reply-c", "reply-c2"]) expect(drawn).toContain(id);
  });
}
