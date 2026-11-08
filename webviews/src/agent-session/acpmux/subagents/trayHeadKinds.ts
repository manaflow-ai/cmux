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
// It is computed when the tray's lists change (an event), never per clock tick.
import type { Translate } from "../i18n";
import { subagentStatus } from "../summary/subagentStatusListModel";
import { sessionRetry } from "./retryState";
import { harnessFamily } from "./agentRuns";
import { commandStatus, type TrayItem } from "./runningTray";
import { COMMAND_KINDS, COMMAND_KIND_COUNT, type CommandKind, commandKind } from "./trayCommandKinds";

export type TrayHeadKindsArm = "kinds" | "plain" | "sub" | "running";

export type TrayHead = {
  /// The counts, joined with the separator (" · " by default).
  text: string;
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
  const parts: (string | false)[] = [
    working ? agents > 0 && t("subagents.allRunning", { n: agents }) : items.length > 0 && t("bgWork.running"),
    !working && agents > 0 && t("subagents.count", { n: agents }),
    sessions > 0 && t("turn.working.sessions", { n: sessions }),
    waitingOnYou > 0 && t("summary.subagents.waiting", { n: waitingOnYou }),
    ...(arm === "running"
      ? [commands > 0 && t("turn.working.commands", { n: commands })]
      : COMMAND_KINDS.map(
          (kind) => (byKind.get(kind) ?? 0) > 0 && t(COMMAND_KIND_COUNT[kind], { n: byKind.get(kind)! }),
        )),
  ];
  if (arm === "running") return { text: joined(parts, separator) || t("summary.subagents"), failed: 0, marks: [] };
  // What ended and stays in the list: done (a session whose turn ended is done), failed, and stopped
  // (cancelled or disconnected: the person or the link ended it), each counted apart.
  let done = 0;
  // Done lines that are not subagents (a chat the agent started, a finished command): with any, the
  // count says "2 done", never "2 subagents done".
  let doneOthers = 0;
  let failed = 0;
  let stopped = 0;
  for (const item of finished) {
    const status =
      item.kind === "agent"
        ? subagentStatus(item.agent, waiting)
        : item.kind === "session"
          ? item.session.state === "failed"
            ? "failed"
            : item.session.state === "idle"
              ? "done"
              : undefined
          : // A finished command that stays a while (trayLinger.ts).
            commandStatus(item.command);
    if (status === "failed") failed += 1;
    else if (status === "stopped") stopped += 1;
    else if (status === "done") {
      done += 1;
      if (item.kind === "command" || (item.kind === "session" && sessionsApart)) doneOthers += 1;
    }
  }
  // All of what ended were subagents (or count as them): "1 subagent done"; a mix says "2 done".
  parts.push(
    done > 0 && (doneOthers === 0 ? t("subagents.allDone", { n: done }) : t("summary.subagents.done", { n: done })),
    // What the person or the link stopped, so a list of only those never heads as a bare "Subagents".
    stopped > 0 && t("summary.subagents.stopped", { n: stopped }),
  );
  return {
    text: joined(parts, separator) || (failed > 0 ? "" : t("summary.subagents")),
    failed,
    marks: arm === "kinds" ? otherFamilies(items, chatHarness) : [],
  };
}

const joined = (parts: readonly (string | false)[], separator: string) =>
  parts.filter((part): part is string => typeof part === "string" && part.length > 0).join(separator);

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
