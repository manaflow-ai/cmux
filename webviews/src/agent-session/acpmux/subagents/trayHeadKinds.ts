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
import {
  COMMAND_KINDS,
  COMMAND_KIND_COUNT,
  COMMAND_KIND_ICON,
  type CommandKind,
  commandKind,
} from "./trayCommandKinds";

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
    // Running work is its mark and count now, never "Running in background" (Leo, 2026-11-23).
    working: _working,
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
    // Between turns too, the work is counted, never headed "Running in background" (Leo, 2026-11-23:
    // "there's no point in even saying it's running").
    agents > 0 && t("subagents.count", { n: agents }),
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

/// One kind in the header's `kinds` arm (trayFoldHead.experiment.ts): its mark, its count in words and
/// the items it counts, so hovering the mark names them (Leo, 2026-11-21, on the open header's "1
/// message · 1 wait": it "almost makes more sense to have at baseline", folded too, its icons "like
/// before" to hover across).
export type TrayHeadPart = {
  key: string;
  /// The kind's mark: a command kind's (trayCommandKinds.ts), a subagent's, a session's, a state's.
  icon: string;
  /// Its count in words ("1 wait", "2 subagents").
  text: string;
  /// What it counts, in list order; the hover names them.
  items: readonly TrayItem[];
  /// A failed count draws in the danger colour, what waits on the person in its tone.
  tone?: "failed" | "waiting";
  /// The tally arm: the subagents' harness, whose mark this part draws (one part per family).
  harness?: string;
  /// Its richest words when they differ from `text` (the `groups` arm's "2 tasks in background").
  long?: string;
};

/// The header's kinds, in the order `trayHead` counts them: what runs (subagents, sessions, what waits
/// on the person, the commands by kind), then what ended (done, stopped, failed). Computed when the
/// tray's lists change, never per tick.
export function trayHeadParts(
  t: Translate,
  {
    items,
    finished,
    waiting,
  }: {
    items: readonly TrayItem[];
    finished: readonly TrayItem[];
    waiting: ReadonlySet<string>;
  },
  /// The tally arm (trayFoldHead.experiment.ts): subagents counted per harness family, and what ended
  /// counted only when it needs the person (failed); done and stopped need nothing, so they go.
  tally = false,
  chatHarness?: string,
): readonly TrayHeadPart[] {
  const agents: TrayItem[] = [];
  const sessions: TrayItem[] = [];
  const waits: TrayItem[] = [];
  const byKind = new Map<CommandKind, TrayItem[]>();
  for (const item of items) {
    if (item.kind === "command") {
      const kind = commandKind(item.command.command);
      const list = byKind.get(kind);
      if (list) list.push(item);
      else byKind.set(kind, [item]);
    } else if (
      item.kind === "agent" ? subagentStatus(item.agent, waiting) === "waiting" : item.session.state === "waiting"
    )
      waits.push(item);
    else if (item.kind === "session") sessions.push(item);
    else agents.push(item);
  }
  const done: TrayItem[] = [];
  const stopped: TrayItem[] = [];
  const failed: TrayItem[] = [];
  let doneOthers = false;
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
          : commandStatus(item.command);
    if (status === "failed") failed.push(item);
    else if (status === "stopped") stopped.push(item);
    else if (status === "done") {
      done.push(item);
      if (item.kind !== "agent") doneOthers = true;
    }
  }
  const parts: TrayHeadPart[] = [];
  const add = (key: string, icon: string, list: readonly TrayItem[], text: string, tone?: TrayHeadPart["tone"]) => {
    if (list.length > 0) parts.push({ key, icon, text, items: list, ...(tone ? { tone } : {}) });
  };
  const n = (list: readonly TrayItem[]) => ({ n: list.length });
  if (tally) {
    // One part per harness family, in the order each first appears (the longest-running first).
    const families = new Map<string, { harness: string | undefined; list: TrayItem[] }>();
    for (const item of agents) {
      const harness = item.kind === "agent" ? (item.agent.harness ?? chatHarness) : chatHarness;
      const family = harness ? harnessFamily(harness) : "";
      const entry = families.get(family);
      if (entry) entry.list.push(item);
      else families.set(family, { harness, list: [item] });
    }
    for (const [family, { harness, list }] of families) {
      const text = t("subagents.count", n(list));
      parts.push({ key: `agents:${family}`, icon: SUBAGENT_ICON, text, items: list, ...(harness ? { harness } : {}) });
    }
  } else add("agents", SUBAGENT_ICON, agents, t("subagents.count", n(agents)));
  add("sessions", "agent.session", sessions, t("turn.working.sessions", n(sessions)));
  add("waiting", "status.needsinput", waits, t("summary.subagents.waiting", n(waits)), "waiting");
  for (const kind of COMMAND_KINDS) {
    const list = byKind.get(kind) ?? [];
    add(kind, COMMAND_KIND_ICON[kind], list, t(COMMAND_KIND_COUNT[kind], n(list)));
  }
  if (tally) {
    add("failed", "status.failure", failed, t("summary.subagents.failed", n(failed)), "failed");
    return parts;
  }
  add(
    "done",
    "status.complete",
    done,
    doneOthers ? t("summary.subagents.done", n(done)) : t("subagents.allDone", n(done)),
  );
  add("stopped", "task.status.canceled", stopped, t("summary.subagents.stopped", n(stopped)));
  add("failed", "status.failure", failed, t("summary.subagents.failed", n(failed)), "failed");
  return parts;
}

/// A subagent's mark when the header draws no harness logo for it (agentIdentityModel.ts).
const SUBAGENT_ICON = "task.ai";

/// One kind's words in the `summary` arm's steps (trayFoldHead.experiment.ts; Leo, 2026-11-23: "x
/// subagents running y commands running etc with full text when you have space and it gradually
/// shrinks when there is none"): long ("2 subagents running"), short ("2 subagents") and the number
/// alone, drawn by its mark. A state kind (waiting, failed) is its state already, so its long form is
/// its short one. A reader always hears the long form.
export type TrayHeadForms = { long: string; short: string; count: string };

export function trayHeadForms(t: Translate, part: TrayHeadPart): TrayHeadForms {
  const short = part.text;
  const n = part.items.length;
  const long = part.long ? part.long : part.tone ? short : t("tray.summary.kindRunning", { kind: short });
  return { long, short, count: String(n) };
}

/// The `groups` arm's two kinds (trayFoldHead.experiment.ts; Leo, 2026-11-24 00:18Z: "the background
/// command type delineation was my doing anyways. the simplest view is just... subagents. other
/// background things. boom. waits, etc, they're just normal tool calls that are backgrounded instead of
/// dozesns of possible different buttons"): the subagents (and the sessions the agent started, chats
/// that run beside it), then every other backgrounded tool call (commands, waits, monitors, servers),
/// whatever it does. The lines under the header keep each item's own mark. Only state that needs the
/// person follows them: what waits on them and what failed. Done and stopped need nothing, so the
/// header drops them, as the `tally` arm does. Computed when the tray's lists change, never per tick.
export function trayHeadGroups(
  t: Translate,
  {
    items,
    finished,
    waiting,
  }: {
    items: readonly TrayItem[];
    finished: readonly TrayItem[];
    waiting: ReadonlySet<string>;
  },
  chatHarness?: string,
): readonly TrayHeadPart[] {
  const agents: TrayItem[] = [];
  const background: TrayItem[] = [];
  const waits: TrayItem[] = [];
  for (const item of items) {
    if (item.kind === "command") background.push(item);
    else if (
      item.kind === "agent" ? subagentStatus(item.agent, waiting) === "waiting" : item.session.state === "waiting"
    )
      waits.push(item);
    else agents.push(item);
  }
  const failed = finished.filter(
    (item) =>
      (item.kind === "agent"
        ? subagentStatus(item.agent, waiting)
        : item.kind === "session"
          ? item.session.state === "failed"
            ? "failed"
            : undefined
          : commandStatus(item.command)) === "failed",
  );
  const parts: TrayHeadPart[] = [];
  if (agents.length > 0) {
    // The group draws the harness most of its subagents run on (the chat's own on a tie).
    const byFamily = new Map<string, { harness: string; n: number }>();
    for (const item of agents) {
      const own =
        (item.kind === "agent" ? item.agent.harness : item.kind === "session" ? item.session.harness : undefined) ??
        chatHarness;
      if (!own) continue;
      const family = harnessFamily(own);
      const entry = byFamily.get(family);
      if (entry) entry.n += 1;
      else byFamily.set(family, { harness: own, n: 1 });
    }
    const chatFamily = chatHarness ? harnessFamily(chatHarness) : undefined;
    let harness: string | undefined;
    let most = 0;
    for (const [family, entry] of byFamily)
      if (entry.n > most || (entry.n === most && family === chatFamily)) {
        harness = entry.harness;
        most = entry.n;
      }
    parts.push({
      key: "agents",
      icon: SUBAGENT_ICON,
      text: t("subagents.count", { n: agents.length }),
      // Running needs no word: the group is what runs.
      long: t("subagents.count", { n: agents.length }),
      items: agents,
      ...(harness ? { harness } : {}),
    });
  }
  if (background.length > 0) {
    const tasks = t(background.length === 1 ? "backgroundTasks.tasks.one" : "backgroundTasks.tasks.other", {
      n: background.length,
    });
    parts.push({
      key: "background",
      icon: BACKGROUND_ICON,
      text: tasks,
      long: t("tray.summary.inBackground", { kind: tasks }),
      items: background,
    });
  }
  if (waits.length > 0)
    parts.push({
      key: "waiting",
      icon: "status.needsinput",
      text: t("summary.subagents.waiting", { n: waits.length }),
      items: waits,
      tone: "waiting",
    });
  if (failed.length > 0)
    parts.push({
      key: "failed",
      icon: "status.failure",
      text: t("summary.subagents.failed", { n: failed.length }),
      items: failed,
      tone: "failed",
    });
  return parts;
}

/// The background group's mark: a command's, since every item it counts is a backgrounded tool call.
const BACKGROUND_ICON = "terminal";
