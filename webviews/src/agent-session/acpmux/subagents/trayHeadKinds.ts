// What the running tray's header counts (SubagentTray.tsx), split by kind (Leo, 2026-11-03: "the top
// should be able to split per background task/scheduled wait/subagent/subsession? ... the top bit aka
// what the collapsed area shows i think can show much more interesting stuf fthan it does now", on a
// header that read only "4 commands 6m 47s" over four commands and a subagent that had finished).
//
// The default arm (trayHeadKinds.experiment.ts `kinds`) reads as Claude desktop's summaries do (#33759,
// "Finished 6 background tasks, ran 5 commands (4 failed)"): what runs, kind by kind (subagents, the
// sessions the agent started, commands, what waits on the person), then what ended in the list, "1
// subagent done", and its failures, "1 failed", which the header draws in the danger colour. A
// session the agent started is a session, not a subagent: it is a chat of its own with its own row in
// the sidebar. A subagent of another model family than the chat's (a Codex subagent under Claude) is
// named by its harness's mark after the counts, as its own line already draws it.
//
// While anything runs, what ended is not counted here: the open list says it on one line of its own,
// "3 finished · 1 failed" (SubagentTray.tsx `EndedFold`), so the header never spends its row on "292
// done · 25 stopped" while it cuts what runs (Leo, 2026-11-12: "why are there ellipses going so fast?
// Like they get truncated and cut off so soon"). Its failures stay, in the danger colour. The counts
// come as parts, most telling first (what runs, what waits on the person, the failures, then the
// commands, waits and plain commands last); the header drops whole parts from the end when its row is
// full, never cutting a word (subagents.css `.acpmux-running-tray__parts`).
//
// It is computed when the tray's lists change (an event), never per clock tick.
import type { Translate } from "../i18n";
import { subagentStatus } from "../summary/subagentStatusListModel";
import { sessionRetry } from "./retryState";
import { harnessFamily } from "./agentRuns";
import { commandStatus, type TrayItem } from "./runningTray";
import { COMMAND_KINDS, COMMAND_KIND_COUNT, type CommandKind, commandKind } from "./trayCommandKinds";

export type TrayHeadKindsArm = "kinds" | "plain" | "sub" | "running";

/// One count of the header: a key that stays while its kind does (its number rolls in place), its
/// words, and whether it is the failures' count (drawn in the danger colour).
export type TrayHeadPart = { readonly key: string; readonly text: string; readonly failed?: true };

export type TrayHead = {
  /// The counts, joined with the separator (" · " by default), the failures' left out.
  text: string;
  /// Every count, the failures' too, most telling first: the header drops them from the end when
  /// its row is full.
  parts: readonly TrayHeadPart[];
  /// What ended failed: drawn after the text in the danger colour ("1 failed"); 0 draws nothing.
  failed: number;
  /// The harnesses of the running subagents and sessions of another model family than the chat's,
  /// each once (at most three), in the order they first show in the list.
  marks: readonly string[];
};

const MAX_MARKS = 3;

export function trayHead(
  t: Translate,
  {
    items,
    finished,
    waiting,
    working,
    chatHarness,
    arm,
    separator = " · ",
  }: {
    items: readonly TrayItem[];
    finished: readonly TrayItem[];
    waiting: ReadonlySet<string>;
    working: boolean;
    chatHarness: string | undefined;
    arm: TrayHeadKindsArm;
    /// Between the counts (trayKindLine.experiment.ts): " · " by default.
    separator?: string;
  },
): TrayHead {
  // Sessions the agent started read as sessions, except in the `sub` and `running` arms, which count
  // them with the subagents as the tray did before.
  const sessionsApart = arm === "kinds" || arm === "plain";
  let agents = 0;
  let sessions = 0;
  let waitingOnYou = 0;
  let commands = 0;
  // The commands by what they do (trayCommandKinds.ts), except in the `running` arm, which keeps the
  // one count it had before (Leo, 2026-11-03: "you can split up commands/waits/bg tasks/subagents").
  const byKind = new Map<CommandKind, number>();
  for (const item of items) {
    if (item.kind === "command") {
      commands += 1;
      const kind = commandKind(item.command.command);
      byKind.set(kind, (byKind.get(kind) ?? 0) + 1);
    } else if (
      item.kind === "agent" ? subagentStatus(item.agent, waiting) === "waiting" : item.session.state === "waiting"
    )
      waitingOnYou += 1;
    else if (item.kind === "session" && sessionsApart) sessions += 1;
    else agents += 1;
  }
  const lead: Part[] = [
    [
      "running",
      working ? agents > 0 && t("subagents.allRunning", { n: agents }) : items.length > 0 && t("bgWork.running"),
    ],
    ["agents", !working && agents > 0 && t("subagents.count", { n: agents })],
    ["sessions", sessions > 0 && t("turn.working.sessions", { n: sessions })],
    ["waiting", waitingOnYou > 0 && t("summary.subagents.waiting", { n: waitingOnYou })],
  ];
  // The commands by kind, in their fixed order but with the waits and the plain commands last: they
  // are the first to go when the row is full (Leo, 2026-11-12, on "7 waits · 11 commands" pushing
  // the rest out).
  const kinds: Part[] =
    arm === "running"
      ? [["commands", commands > 0 && t("turn.working.commands", { n: commands })]]
      : [...COMMAND_KINDS]
          .sort((a, b) => Number(LOW_KINDS.has(a)) - Number(LOW_KINDS.has(b)))
          .map((kind) => [kind, (byKind.get(kind) ?? 0) > 0 && t(COMMAND_KIND_COUNT[kind], { n: byKind.get(kind)! })]);
  if (arm === "running") {
    const parts = shown([...lead, ...kinds]);
    const text = parts.map((part) => part.text).join(separator) || t("summary.subagents");
    return { text, parts: parts.length > 0 ? parts : [{ key: "subagents", text }], failed: 0, marks: [] };
  }
  // What ended and stays in the list: done (a session whose turn ended is done), failed, and stopped
  // (cancelled or disconnected: the person or the link ended it), each counted apart.
  let done = 0;
  // Done lines that are not subagents (a chat the agent started, a finished command): with any, the
  // count says "2 done", never "2 subagents done".
  let doneOthers = 0;
  let failed = 0;
  let stopped = 0;
  for (const item of finished) {
    const status = endedStatus(item, waiting);
    if (status === "failed") failed += 1;
    else if (status === "stopped") stopped += 1;
    else if (status === "done") {
      done += 1;
      if (item.kind === "command" || (item.kind === "session" && sessionsApart)) doneOthers += 1;
    }
  }
  // Nothing runs: what ended is all there is to say. All of it were subagents (or count as them): "1
  // subagent done"; a mix says "2 done"; what the person or the link stopped too, so a list of only
  // those never heads as a bare "Subagents". While anything runs, the open list's "N finished" line
  // says it instead.
  const ended: Part[] =
    items.length > 0
      ? []
      : [
          [
            "done",
            done > 0 &&
              (doneOthers === 0 ? t("subagents.allDone", { n: done }) : t("summary.subagents.done", { n: done })),
          ],
          ["stopped", stopped > 0 && t("summary.subagents.stopped", { n: stopped })],
        ];
  const words = shown([...lead, ...ended]);
  const tail = shown(kinds);
  const failedPart: TrayHeadPart[] =
    failed > 0 ? [{ key: "failed", text: t("summary.subagents.failed", { n: failed }), failed: true }] : [];
  const text = [...words, ...tail].map((part) => part.text).join(separator);
  const parts = [...words, ...failedPart, ...tail];
  return {
    text: text || (failed > 0 ? "" : t("summary.subagents")),
    parts: parts.length > 0 ? parts : [{ key: "subagents", text: t("summary.subagents") }],
    failed,
    marks: arm === "kinds" ? otherFamilies(items, chatHarness) : [],
  };
}

/// A count by its key, or false where there is none of its kind.
type Part = readonly [string, string | false];
const shown = (parts: readonly Part[]): TrayHeadPart[] =>
  parts.flatMap(([key, text]) => (typeof text === "string" && text.length > 0 ? [{ key, text }] : []));

/// The command kinds that go first when the header's row is full: waits on a timer or CI, and
/// commands with no kind of their own.
const LOW_KINDS: ReadonlySet<CommandKind> = new Set(["waits", "commands"]);

/// The open list's line for what ended (SubagentTray.tsx `EndedFold`): "3 finished · 1 failed", what
/// completed or was stopped as finished, the failures apart, in the danger colour.
export function endedCounts(
  finished: readonly TrayItem[],
  waiting: ReadonlySet<string>,
): { finished: number; failed: number } {
  let failed = 0;
  for (const item of finished) if (endedStatus(item, waiting) === "failed") failed += 1;
  return { finished: finished.length - failed, failed };
}

/// What an ended line came to: done, failed or stopped (a chat the agent started is done when idle).
function endedStatus(item: TrayItem, waiting: ReadonlySet<string>) {
  return item.kind === "agent"
    ? subagentStatus(item.agent, waiting)
    : item.kind === "session"
      ? item.session.state === "failed"
        ? "failed"
        : item.session.state === "idle"
          ? "done"
          : undefined
      : // A finished command that stays a while (trayLinger.ts).
        commandStatus(item.command);
}

/// The harnesses of the running work of another model family than the chat's (a Codex subagent or
/// session under a Claude chat), each family once.
function otherFamilies(items: readonly TrayItem[], chatHarness: string | undefined): string[] {
  if (!chatHarness) return [];
  const own = harnessFamily(chatHarness);
  const seen = new Set<string>();
  const marks: string[] = [];
  for (const item of items) {
    const harness =
      item.kind === "agent"
        ? item.agent.harness
        : item.kind === "session" && (item.session.state !== "idle" || sessionRetry(item.session).kind === "retrying")
          ? item.session.harness
          : undefined;
    if (!harness) continue;
    const family = harnessFamily(harness);
    if (family === own || seen.has(family)) continue;
    seen.add(family);
    marks.push(harness);
    if (marks.length === MAX_MARKS) break;
  }
  return marks;
}
