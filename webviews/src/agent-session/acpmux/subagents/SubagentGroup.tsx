// A batch of subagents inline in the transcript, after the ChatGPT and T3 Code apps: one line with
// their avatars, "4 subagents", how many are working or done, the time since the first started,
// and a chevron; opened, a bordered list with a row per subagent (SUBAGENT_ROW rows below it).
// Every line has a fixed height (model.ts), so a running clock or a changing status never moves
// the transcript.
import { createContext, useContext, useEffect, useState } from "react";
import { Icon } from "../icons/Icon";
import { AgentMark, agentBrand } from "../../shared/AgentMark";
import { usePaneLanguage, useT, type PaneLanguage, type Translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "../conversation/turns";
import type { Subagent } from "./subagentFold";
import { AgentTonesContext } from "./agentTones";
import { subagentProgress } from "./subagentProgress";

/// The chat's harness (claude, codex, ...): its subagents run on it, so their avatars carry its mark.
export const SubagentHarnessContext = createContext<string | undefined>(undefined);

/// Opens a subagent's own view in the pane, or the session's own with undefined (App.tsx).
export const SubagentNavContext = createContext<((id: string | undefined) => void) | undefined>(undefined);

/// Shows a subagent in a pane of its own right of the chat, or in this pane when none opens
/// (App.tsx, subagentPanes.ts). A group's subagent line uses it; the child view's pill goes back
/// in place.
export const SubagentPaneContext = createContext<((id: string) => void) | undefined>(undefined);

/// Stops a running subagent (App.tsx, direct.ts `stopSubagent`), settling with Claude's answer;
/// absent where the harness cannot.
export const SubagentStopContext = createContext<((id: string) => Promise<unknown>) | undefined>(undefined);

/// Avatars drawn before "+N".
const STACK = 3;

export const running = (agent: Subagent) => agent.state === "running";

/// Each subagent state's label in an open group.
export const STATE_LABEL = {
  running: "subagents.state.running",
  completed: "subagents.state.completed",
  failed: "subagents.state.failed",
  cancelled: "subagents.state.cancelled",
  disconnected: "subagents.state.disconnected",
} as const;

/// Milliseconds a subagent has run: until it ended, or until `now`.
export const elapsed = (agent: Subagent, now: number) => Math.max(0, (agent.endedAt ?? now) - agent.startedAt);

/// The group's time: from its first start to its last end, or to `now` while one runs.
export function groupElapsed(agents: readonly Subagent[], now: number): number {
  if (agents.length === 0) return 0;
  const start = Math.min(...agents.map((agent) => agent.startedAt));
  const end = agents.some(running) ? now : Math.max(...agents.map((agent) => agent.endedAt ?? agent.startedAt));
  return Math.max(0, end - start);
}

/// The current time, ticking each second only while `live`.
export function useNow(live: boolean): number {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!live) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [live]);
  return now;
}

function Avatar({ agent, dot = false }: { agent: Subagent; dot?: boolean }) {
  const harness = useContext(SubagentHarnessContext);
  return (
    <span className="cv-subagent-avatar" data-state={agent.state}>
      {agentBrand(harness) ? <AgentMark agent={harness} size={14} /> : <Icon name="agent.session" size={14} />}
      {dot && <span className="cv-subagent-avatar__dot" aria-hidden="true" />}
    </span>
  );
}

/// The group's one line (Leo 2026-10-13): "1 subagent running", "3 subagents done", or the count
/// and what is still going, "2 subagents, 1 running" (and any failed; done ones once none run).
/// Each count takes the pane language's plural form.
function groupLabel(t: Translate, language: PaneLanguage, agents: readonly Subagent[]): string {
  const n = agents.length;
  const count = (state: string) => agents.filter((agent) => agent.state === state).length;
  const [runningCount, failed, done] = [count("running"), count("failed"), count("completed")];
  if (n > 0 && runningCount === n) return t("subagents.allRunning", { n });
  if (n > 0 && done === n) return t("subagents.allDone", { n });
  if (n > 0 && failed === n) return t("subagents.allFailed", { n });
  const states = [
    runningCount > 0 && t("summary.subagents.running", { n: runningCount }),
    failed > 0 && t("summary.subagents.failed", { n: failed }),
    runningCount === 0 && done > 0 && t("summary.subagents.done", { n: done }),
  ].filter((part): part is string => typeof part === "string");
  const total = t("subagents.count", { n });
  if (states.length === 0) return total;
  const list = new Intl.ListFormat(language, { type: "unit", style: "short" }).format(states);
  return t("subagents.countAndStates", { count: total, states: list });
}

export function SubagentGroupHeader({
  row,
  expanded,
  onToggle,
}: {
  row: AcpmuxRow;
  expanded: boolean;
  onToggle: () => void;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const agents = row.subagents ?? [];
  const live = agents.some(running);
  const now = useNow(live);
  const controls = expanded ? agents.map((agent) => `${row.id}:${agent.id}`).join(" ") : undefined;
  return (
    <button type="button" className="cv-subagents" aria-expanded={expanded} aria-controls={controls} onClick={onToggle}>
      <span className="cv-subagents__stack" aria-hidden="true">
        {agents.slice(0, STACK).map((agent) => (
          <Avatar key={agent.id} agent={agent} />
        ))}
        {agents.length > STACK && <span className="cv-subagents__more">+{agents.length - STACK}</span>}
      </span>
      <span className="cv-subagents__text">
        <span className="cv-subagents__title">{groupLabel(t, language, agents)}</span>
      </span>
      <span className="cv-subagents__time">{formatDuration(groupElapsed(agents, now))}</span>
      <Icon name={expanded ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
    </button>
  );
}

/// One subagent in an open group: its avatar with a status dot, name (in the agent's color,
/// agentTones.ts), state or current action with what it has spent (subagentProgress.ts), and time. `edge` rounds the list's first and last
/// rows. A click opens its own view; a running one has a stop button beside it.
export function SubagentListRow({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const language = usePaneLanguage();
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const open = pane ?? nav;
  const stop = useContext(SubagentStopContext);
  const tones = useContext(AgentTonesContext);
  const agent = row.subagents?.[0];
  const now = useNow(agent ? running(agent) : false);
  if (!agent) return null;
  const label = STATE_LABEL[agent.state as keyof typeof STATE_LABEL] ?? STATE_LABEL.completed;
  const state = [running(agent) ? (agent.action ?? t(label)) : t(label), ...subagentProgress(t, language, agent)].join(
    " · ",
  );
  const content = (
    <>
      <Avatar agent={agent} dot />
      <span className="cv-subagent__text">
        <span className="cv-subagent__name">
          {agent.name}
          {agent.kind && agent.kind !== agent.name && <span className="cv-subagent__kind">{agent.kind}</span>}
        </span>
        <span className="cv-subagent__state">{state}</span>
      </span>
      <span className="cv-subagent__time">{formatDuration(elapsed(agent, now))}</span>
    </>
  );
  const line = !open ? (
    <div id={row.id} className="cv-subagent" data-edge={row.status} data-agent-tone={tones?.get(agent.id)}>
      {content}
    </div>
  ) : (
    <button
      type="button"
      id={row.id}
      className="cv-subagent"
      data-edge={row.status}
      data-agent-tone={tones?.get(agent.id)}
      aria-label={t("subagents.open", { name: agent.name })}
      onClick={() => open(agent.id)}
    >
      {content}
      <Icon name="disclosure.collapsed" size={12} />
    </button>
  );
  if (!stop || !running(agent)) return line;
  return (
    <div className="cv-subagent-stoppable">
      {line}
      <StopButton agent={agent} stop={stop} />
    </div>
  );
}

/// A running subagent's stop button. It stays off while Claude has the request (and after Claude
/// takes it, until the subagent ends); when acpmux or Claude refuses, it says so and can be tried
/// again.
function StopButton({ agent, stop }: { agent: Subagent; stop: (id: string) => Promise<unknown> }) {
  const t = useT();
  const [state, setState] = useState<"idle" | "stopping" | "failed">("idle");
  const label = t(state === "failed" ? "subagents.stopFailed" : "subagents.stop", { name: agent.name });
  return (
    <button
      type="button"
      className="cv-subagent__stop"
      data-state={state}
      disabled={state === "stopping"}
      aria-label={label}
      title={label}
      onClick={() => {
        setState("stopping");
        stop(agent.id).catch(() => setState("failed"));
      }}
    >
      <Icon name="action.stop" size={12} />
    </button>
  );
}

/// The child view's first line: a "Subagent of" pill naming the agent that spawned it (`text`);
/// a click goes back to that agent's view, or to the session's own.
export function SubagentOfRow({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const open = useContext(SubagentNavContext);
  const agent = row.subagents?.[0];
  if (!agent) return null;
  return (
    <div className="cv-subagent-of">
      <button type="button" className="cv-subagent-of__pill" onClick={() => open?.(agent.parent ?? undefined)}>
        <Icon name="agent.session" size={12} />
        <span className="cv-subagent-of__label">{t("subagents.of")}</span>
        <span className="cv-subagent-of__parent">{row.text}</span>
      </button>
    </div>
  );
}
