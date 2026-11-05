// What a Claude workflow's card (WorkflowCard.tsx) and Session Info's Background tasks
// (session-info/WorkflowTasks.tsx) show of it, as pure functions of the folded workflow
// (foldWorkflows.ts), so both read it the same way and the tests read it without a render.
//
// Leo (2026-11-05), on our card and panel beside Claude's: "there are areas to improve on around
// here", and on the list drawn from it: "Definitely just build it." From that list:
// - Running and Finished are separate: an agent that ended leaves the running list (`splitAgents`).
// - The phases no agent has reached read "Up next: <phases>" (`upNext`), never empty headings.
// - An agent row says what it does in words (`agentLine`), never its last shell command, and a
//   finished one opens to its output, rendered (`outputMarkdown`), never raw JSON.
// - The card names every phase that runs (`runningPhases`) and, while agents may still spawn,
//   counts what is done and running rather than a total that is not one yet (`cardCount`).
// - The model shows once for the workflow (`workflowModel`), and on an agent only where it
//   differs (`agentModel`).
// - A shell command one of its agents started is that agent's (`attributeCommands`), never the
//   chat's own.
import type { BackgroundCommand } from "../session-info/processes";
import { phaseAgents, phaseState, tally } from "./foldWorkflows";
import type { WorkflowAgent, WorkflowPhase, WorkflowSummary } from "./workflow";

/// An agent that ended: done, failed or cancelled.
export const agentEnded = (agent: Pick<WorkflowAgent, "state">): boolean =>
  agent.state === "completed" || agent.state === "failed" || agent.state === "cancelled";

const endOf = (agent: WorkflowAgent): number =>
  agent.startedAt !== undefined ? agent.startedAt + (agent.elapsedMs ?? 0) : (agent.index ?? 0);

/// The agents still running or waiting to (in the workflow's order), and the ones that ended, the
/// latest end first, as Claude's Finished list reads.
export function splitAgents(agents: readonly WorkflowAgent[]): {
  running: WorkflowAgent[];
  finished: WorkflowAgent[];
} {
  return {
    running: agents.filter((agent) => !agentEnded(agent)),
    finished: agents.filter(agentEnded).sort((a, b) => endOf(b) - endOf(a) || a.id.localeCompare(b.id)),
  };
}

/// The phases a running workflow lists as rows: every one an agent of it reached. A phase none has
/// reached is not a row; they are the "Up next" line (`upNext`). A workflow that ended
/// lists every phase, since nothing comes next.
export function listedPhases(workflow: WorkflowSummary): WorkflowPhase[] {
  if (workflow.state !== "running") return workflow.phases;
  return workflow.phases.filter((phase) => phaseAgents(workflow, phase).length > 0);
}

/// The phases a running workflow comes to next, in order: every one no agent has reached. None once
/// it ended.
export function upNext(workflow: WorkflowSummary): WorkflowPhase[] {
  if (workflow.state !== "running") return [];
  return workflow.phases.filter((phase) => phaseAgents(workflow, phase).length === 0 && phase.name);
}

/// Names joined as the pane's language lists them ("Latency plan, Swarm synthesis").
export function listNames(names: readonly string[], language?: string): string {
  try {
    return new Intl.ListFormat(language, { style: "short", type: "unit" }).format(names);
  } catch {
    return names.join(", ");
  }
}

/// The phases with an agent running now, in order: two can run at once.
export function runningPhases(workflow: WorkflowSummary): WorkflowPhase[] {
  return workflow.phases.filter((phase) => phaseState(phaseAgents(workflow, phase)) === "running");
}

/// What a phase's row counts: its agents that ended well, of the ones it has.
export function phaseCount(workflow: WorkflowSummary, phase: WorkflowPhase): { done: number; total: number } {
  const counts = tally(phaseAgents(workflow, phase));
  return { done: counts.done, total: counts.total };
}

/// The card's count. A running workflow whose agents may still spawn (a phase not reached yet, or
/// agents queued) has no total yet: it counts what is done and what runs. Otherwise done of total.
export function cardCount(
  workflow: WorkflowSummary,
): { kind: "progress"; done: number; running: number; total: number } | { kind: "total"; done: number; total: number } {
  const counts = tally(workflow.agents);
  const reported = (workflow.counts?.started ?? 0) + (workflow.counts?.queued ?? 0);
  const total = Math.max(counts.total, reported);
  const done = Math.min(total, Math.max(counts.done, workflow.counts?.done ?? 0));
  const open =
    workflow.state === "running" &&
    (upNext(workflow).length > 0 || counts.queued > 0 || counts.running > 0 || done < total);
  return open ? { kind: "progress", done, running: counts.running, total } : { kind: "total", done, total };
}

/// The model most of the workflow's agents run on (the first named on a tie); none when no agent
/// names one.
export function workflowModel(agents: readonly WorkflowAgent[]): string | undefined {
  const counts = new Map<string, number>();
  for (const agent of agents) if (agent.model) counts.set(agent.model, (counts.get(agent.model) ?? 0) + 1);
  let best: string | undefined;
  for (const [model, n] of counts) if (best === undefined || n > counts.get(best)!) best = model;
  return best;
}

/// The workflow's model and effort as its agents mostly run, which each agent row then leaves out.
export function sharedModel(agents: readonly WorkflowAgent[]): { model?: string; effort?: string } {
  const model = workflowModel(agents);
  const efforts = new Map<string, number>();
  for (const agent of agents) if (agent.effort) efforts.set(agent.effort, (efforts.get(agent.effort) ?? 0) + 1);
  let effort: string | undefined;
  for (const [each, n] of efforts) if (effort === undefined || n > efforts.get(effort)!) effort = each;
  return { model, effort };
}

/// What an agent's row names besides its name: its model where it is not the workflow's (with its
/// effort), else its effort alone where only that differs. None where both are the workflow's.
export function agentModelLabel(
  agent: WorkflowAgent,
  shared: { model?: string; effort?: string },
): { model?: string; effort?: string } | undefined {
  const model = agentModel(agent, shared.model);
  if (model) return { model, ...(agent.effort ? { effort: agent.effort } : {}) };
  return agent.effort && agent.effort !== shared.effort ? { effort: agent.effort } : undefined;
}

/// An agent's model where it is not the workflow's; none where it is (the workflow names it once).
export function agentModel(agent: WorkflowAgent, model: string | undefined): string | undefined {
  return agent.model && agent.model !== model ? agent.model : undefined;
}

/// The words a shell line starts with that make it a command rather than a sentence.
const PROGRAMS = new Set(
  (
    "cd ls cat rg grep sed awk git gh bun bunx npm npx pnpm yarn node deno python python3 pip uv cargo " +
    "rustc go make cmake swift xcodebuild xcrun curl wget jq yq find head tail echo printf sleep timeout " +
    "env export source sh bash zsh ssh scp rsync docker kubectl tar unzip mkdir rm mv cp touch chmod " +
    "wc sort uniq xargs tee diff sudo open acpmux cmux cmux-ci glaeda-gh reach wt test true false"
  ).split(" "),
);

/// Whether `text` reads as a shell command (`cd ~/x && …`, `f=~/.claude/…`, `timeout 30 acpmux …`)
/// rather than words: a program or an assignment first, or shell punctuation.
export function looksLikeCommand(text: string): boolean {
  const line = text.trim();
  if (!line) return false;
  if (/&&|\|\||\$\(|`|\s\|\s|\s2>&1/.test(line)) return true;
  // `;` joins commands only when a program follows it; in a sentence it joins clauses.
  if ([...line.matchAll(/;\s*(\S+)/g)].some((match) => PROGRAMS.has(match[1]!))) return true;
  const first = line.split(/\s+/, 1)[0]!;
  if (/^[A-Za-z_]\w*=/.test(first)) return true;
  if (/^(?:~|\.{0,2}\/)/.test(first)) return true;
  return PROGRAMS.has(first);
}

/// Whether `text` starts as a JSON object or array, not as Markdown that opens with a bracket (a
/// `[link](…)` or a `[x]` checklist).
const looksLikeJson = (text: string): boolean => /^\s*(?:\{\s*(?:"|\}|$)|\[\s*(?:[[{"\]]|$))/.test(text);

/// The first line of `text`, Markdown marks and runs of space folded, for a one-line subtitle.
export const firstLine = (text: string | undefined): string | undefined => {
  const line = text
    ?.split("\n")
    .map((part) => part.trim())
    .find(Boolean);
  // Emphasis only where it pairs (`**word**`, `_word_`), so `workflow_agent_id` and `2*3` keep theirs.
  return (
    line
      ?.replace(/^#+\s*/, "")
      .replace(/(\*\*|__|\*|_)(?=\S)(.+?)(?<=\S)\1(?![\w*])/g, "$2")
      .replace(/`/g, "")
      .replace(/\s+/g, " ") || undefined
  );
};

/// What a row says an agent does, in words. Failed: its reason. Running or waiting: its latest
/// message or step in words, else what it was asked to do; a shell command or JSON never. Ended
/// well: nothing, since its row opens to its output (`outputMarkdown`).
export function agentLine(agent: WorkflowAgent): string | undefined {
  if (agent.state === "failed") return agent.error ?? firstLine(agent.lastMessage);
  if (agentEnded(agent)) return undefined;
  for (const text of [agent.lastMessage, agent.doing]) {
    const line = firstLine(text);
    if (line && !looksLikeCommand(line) && !looksLikeJson(line)) return line;
  }
  return firstLine(agent.prompt);
}

/// The string fields a result names its prose by, in the order they are preferred.
const PROSE = ["summary", "result", "output", "answer", "report", "text", "message", "content"];

/// A JSON string literal's body, read leniently: a preview cut mid-escape keeps what it has.
const unquote = (body: string): string => {
  try {
    return JSON.parse(`"${body.replace(/\\$/, "")}"`) as string;
  } catch {
    return body.replace(/\\n/g, "\n").replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  }
};

/// An agent's output as Markdown to render: its text as it is, or for a JSON result (Claude's
/// structured output, `{"summary":"I compared…"}`) its prose field, else each field as a line. A
/// preview cut short (Claude sends 240 characters) still reads: its prose field is taken up to the
/// cut. None when it has no output.
export function outputMarkdown(agent: WorkflowAgent): string | undefined {
  const raw = (agent.result ?? agent.lastMessage)?.trim();
  if (!raw) return undefined;
  if (!looksLikeJson(raw)) return raw;
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    // A cut preview: the first prose field present, up to where the preview ends.
    for (const key of PROSE) {
      const match = new RegExp(`"${key}"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)("|\\\\?$)`).exec(raw);
      if (match) return unquote(match[1]!) + (match[2] === '"' ? "" : "…");
    }
    return "```json\n" + raw + "\n```";
  }
  if (typeof value === "string") return value;
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const record = value as Record<string, unknown>;
    for (const key of PROSE) if (typeof record[key] === "string" && record[key]) return record[key] as string;
    const lines = Object.entries(record).flatMap(([key, field]) =>
      field === null || typeof field === "object" ? [] : [`- **${key}**: ${String(field)}`],
    );
    if (lines.length > 0) return lines.join("\n");
  }
  return "```json\n" + JSON.stringify(value, null, 2) + "\n```";
}

/// The chat's background commands split by who started them: the ones a workflow's agent started
/// (the registry names the workflow as the subagent, and the agent by Claude's agent id,
/// `workflowAgent`) go under that agent, the ones only the workflow is known for under the
/// workflow, and the rest stay the chat's own.
export type WorkflowCommands = {
  /// By workflow agent id (`WorkflowAgent.id`).
  byAgent: ReadonlyMap<string, BackgroundCommand[]>;
  /// By workflow id: the workflow's commands no agent of it is known for.
  byWorkflow: ReadonlyMap<string, BackgroundCommand[]>;
};

export function attributeCommands(
  commands: readonly BackgroundCommand[],
  workflows: readonly WorkflowSummary[],
): { own: BackgroundCommand[]; workflows: WorkflowCommands } {
  const byAgent = new Map<string, BackgroundCommand[]>();
  const byWorkflow = new Map<string, BackgroundCommand[]>();
  const own: BackgroundCommand[] = [];
  const add = (map: Map<string, BackgroundCommand[]>, key: string, command: BackgroundCommand) =>
    map.set(key, [...(map.get(key) ?? []), command]);
  for (const command of commands) {
    const workflow = workflows.find(
      (each) =>
        (command.subagent !== undefined && each.id === command.subagent) ||
        (command.workflowAgent !== undefined &&
          (command.subagent === undefined || command.subagent === each.id) &&
          each.agents.some((agent) => agent.agentId === command.workflowAgent)),
    );
    if (!workflow) {
      own.push(command);
      continue;
    }
    const agent =
      command.workflowAgent !== undefined
        ? workflow.agents.find((each) => each.agentId === command.workflowAgent)
        : undefined;
    if (agent) add(byAgent, agent.id, command);
    else add(byWorkflow, workflow.id, command);
  }
  return { own, workflows: { byAgent, byWorkflow } };
}

/// The card's latest line, in words, and the agent it is from: while it runs, what its most recently
/// active agent that says anything does (`agentLine`); once it ended, the first line of its last
/// agent's output.
export function cardLine(workflow: WorkflowSummary): { agent: string; line: string } | undefined {
  const active = (agent: WorkflowAgent) => agent.lastProgressAt ?? agent.startedAt ?? 0;
  const live = workflow.agents
    .filter((agent) => agent.state === "running" || agent.state === "paused")
    .sort((a, b) => active(b) - active(a));
  for (const agent of live) {
    const line = agentLine(agent);
    if (line) return { agent: agent.name, line };
  }
  if (workflow.state === "running") return undefined;
  const last = splitAgents(workflow.agents).finished[0];
  const line = last && firstLine(outputMarkdown(last)?.replace(/^```\w*$/gm, ""));
  return last && line ? { agent: last.name, line } : undefined;
}
