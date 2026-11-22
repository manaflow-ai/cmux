// The Chief's background tasks in the composer hat (Leo, 2026-11-10: "keeping track of background
// tasks, like how Claude Code does it and how I've wanted to do it in the composer hat. Things
// eventually just expire."). A Task is a helper the Chief started with no workspace
// (optchat-chief action_lifetime.rs): its `spawn` step answers `- a12: hidden: …`. Its row runs until a `[a12] …` note (its report, or the stopped note)
// ends it with a one-line result, then expires from the hat `HAT_TTL_MS` later; the chat keeps it.
// Read from the runs the page already holds (`RunBook`), newest `MAX_RUNS` of the conversation, so
// the cost does not grow with the chat.
import type { RunEntry } from "./runs";
import type { HomeRunStep } from "./types";

/** How long a finished task stays in the hat (action_lifetime.rs `HAT_TTL`). */
export const HAT_TTL_MS = 10 * 60_000;
/** A Task is short by its routing (a long one gets a workspace): one with no end after this shows
 * as stalled, once, and is never prodded. */
export const TASK_STALL_MS = 30 * 60_000;
/** A task with no end after this leaves the hat: a stop the page never heard of (a cancel from
 * the agent's own chat) ended it. */
export const TASK_GONE_MS = 3 * 3600_000;
const CONTROL_TOOLS = new Set(["control", "optchat.control", "mcp__optchat__control"]);
const ENDING_ACTIONS = new Set(["cancel", "stop"]);
/** The newest runs of a conversation read for tasks. */
export const MAX_RUNS = 40;
/** Characters of a result line. */
const RESULT_CHARS = 120;
const SPAWN_TOOLS = new Set(["spawn", "optchat.spawn", "mcp__optchat__spawn"]);

export type ChiefTaskState = "running" | "stalled" | "done" | "stopped";

export interface ChiefTask {
  /** Unique in the conversation: its Chief and its id (each Chief counts `a1` on its own). */
  key: string;
  id: string;
  title: string;
  state: ChiefTaskState;
  startedAt: number;
  endedAt?: number;
  /** Its report's first line, or why it stopped. */
  result?: string;
}

/** A task's title from its `Title:` line, else its first line. */
function taskTitle(task: unknown, id: string): string {
  if (typeof task !== "string") return id;
  const lines = task
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
  const titled = lines.slice(0, 3).find((l) => /^title:/i.test(l));
  if (titled) return titled.replace(/^title:\s*/i, "") || id;
  return lines.find((l) => !/^(group|sidebar|expect):/i.test(l)) ?? id;
}

function clip(text: string): string {
  const line =
    text
      .split("\n")
      .find((l) => l.trim())
      ?.trim() ?? "";
  return line.length > RESULT_CHARS ? `${line.slice(0, RESULT_CHARS - 1).trimEnd()}…` : line;
}

/** The background tasks a spawn step started: `- aN: hidden: …` lines, with the task's
 * title when the input's tasks line up with the answer's ids. */
function spawned(step: HomeRunStep): ChiefTask[] {
  const tool = step.tool;
  if (step.kind !== "tool" || !tool || !SPAWN_TOOLS.has(tool.name) || !tool.output) return [];
  const tasks = (tool.input as { tasks?: unknown } | undefined)?.tasks;
  const lines = tool.output.split("\n").filter((l) => /^- a\d+:/.test(l));
  const aligned = Array.isArray(tasks) && tasks.length === lines.length ? tasks : undefined;
  const out: ChiefTask[] = [];
  lines.forEach((line, index) => {
    const match = /^- (a\d+): (.*)$/.exec(line);
    if (!match) return;
    const [, id, answer] = match;
    if (!answer!.startsWith("hidden:")) return;
    out.push({
      key: id!,
      id: id!,
      title: taskTitle(aligned?.[index], id!),
      state: "running",
      startedAt: tool.startedAt ?? step.at,
    });
  });
  return out;
}

/** The task a `control cancel` step of the Chief stopped. */
function cancelled(step: HomeRunStep): string | undefined {
  const tool = step.tool;
  if (step.kind !== "tool" || !tool || !CONTROL_TOOLS.has(tool.name)) return undefined;
  // Only a call that went through: a refused or failed cancel leaves the task running.
  if (step.status === "failed" || /^(error|refused|outcome: refused)/i.test(tool.output ?? "")) return undefined;
  const input = tool.input as { action?: unknown; id?: unknown } | undefined;
  return typeof input?.action === "string" && ENDING_ACTIONS.has(input.action) && typeof input.id === "string"
    ? input.id
    : undefined;
}

/** What a note says of a task: `[aN] text` ends it; `[aN] is stuck: …` marks it stalled once. */
function noted(step: HomeRunStep): { id: string; text: string } | undefined {
  if (step.kind !== "note") return undefined;
  const match = /^\[(a\d+)\] ([\s\S]*)$/.exec(step.text ?? "");
  return match ? { id: match[1]!, text: match[2]! } : undefined;
}

/** The hat's tasks at `now` from a conversation's run entries: running first (oldest first), then
 * finished ones not yet expired (latest first). */
export function chiefTasks(entries: readonly RunEntry[], now: number): ChiefTask[] {
  const runs = [...entries].sort((a, b) => a.run.startedAt - b.run.startedAt).slice(-MAX_RUNS);
  // Subagent ids are each Chief's own: a task is keyed by its Chief (the run's author) too.
  const tasks = new Map<string, ChiefTask>();
  for (const { run, steps } of runs) {
    const key = (id: string) => `${run.author}\0${id}`;
    for (const step of steps) {
      for (const task of spawned(step)) tasks.set(key(task.id), { ...task, key: key(task.id) });
      const stop = cancelled(step);
      const stopping = stop ? tasks.get(key(stop)) : undefined;
      if (stopping && (stopping.state === "running" || stopping.state === "stalled")) {
        stopping.state = "stopped";
        stopping.endedAt = step.at;
      }
      const note = noted(step);
      const task = note && tasks.get(key(note.id));
      if (!note || !task || task.state === "done" || task.state === "stopped") continue;
      if (note.text.startsWith("is stuck")) {
        task.state = "stalled";
        continue;
      }
      const stopped = note.text.startsWith("(stopped");
      task.state = stopped ? "stopped" : "done";
      task.endedAt = step.at;
      task.result = clip(stopped ? note.text.replace(/^\(|\)$/g, "") : note.text);
    }
  }
  const all = [...tasks.values()].filter((t) => t.endedAt !== undefined || now - t.startedAt < TASK_GONE_MS);
  for (const t of all) if (t.state === "running" && now - t.startedAt >= TASK_STALL_MS) t.state = "stalled";
  const live = all.filter((t) => t.state === "running" || t.state === "stalled");
  const ended = all
    .filter((t) => t.endedAt !== undefined && now - t.endedAt < HAT_TTL_MS)
    .sort((a, b) => b.endedAt! - a.endedAt!);
  return [...live.sort((a, b) => a.startedAt - b.startedAt), ...ended];
}

/** When the hat next changes by itself: the earliest finished task's expiry; undefined when none. */
export function nextExpiry(tasks: readonly ChiefTask[]): number | undefined {
  const at = tasks.flatMap((t) =>
    t.endedAt !== undefined
      ? [t.endedAt + HAT_TTL_MS]
      : t.state === "running"
        ? [t.startedAt + TASK_STALL_MS]
        : [t.startedAt + TASK_GONE_MS],
  );
  return at.length ? Math.min(...at) : undefined;
}
