// A batch of subagents inline in the transcript, after the ChatGPT and T3 Code apps: one line with
// their avatars, "4 subagents", how many are working or done, the time since the first started,
// and a chevron; opened, a bordered list with a row per subagent (SUBAGENT_ROW rows below it).
// Every line has a fixed height (model.ts), so a running clock or a changing status never moves
// the transcript.
import { useContext, useState } from "react";
import { Icon } from "../icons/Icon";
import { usePaneLanguage, useT, type PaneLanguage, type Translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { type Subagent } from "./subagentFold";
import { agentTone, AgentTonesContext } from "./agentTones";
import { AgentIdentity } from "./AgentIdentity";
import { foreignHarness, isRepeatedAgentKind, SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { useSenderIconLook } from "./senderIconLook";
import { subagentProgress } from "./subagentProgress";
import { orderedCountWords } from "../session-info/subagentsSectionModel";
import { subagentDisplayName } from "./subsessions";
import { namedAction } from "./trayDetail";
import { waveProps } from "../../../ui/wave";
import { TurnActionsContext } from "../conversation/turnActions";
import { ResumeControl } from "./ResumeControl";
import { canResume } from "./resumeState";
import {
  SubagentHarnessContext,
  SubagentNavContext,
  SubagentPaneContext,
  SubagentStopContext,
  running,
  STATE_LABEL,
  ticking,
  subagentTime,
  useNow,
  STACK,
} from "./subagentGroupModel";
import { Clock } from "../../../ui/Typography";
import { Elapsed } from "./Elapsed";
import { intl } from "../../../ui/intl";

/// A subagent's avatar: the subagent mark in the agent's tone (another family's harness mark,
/// AgentIdentity.tsx `foreignHarness`), and its place in the running wave
/// (ui/wave.ts) when `wave` is set. No status dot on its corner: the row says the state in words
/// (Leo 2026-10-22: "the bottom right dots in most situations is kinda weird and unnecsesary").
export function Avatar({ agent, wave }: { agent: Subagent; wave?: number }) {
  // An agent a shell call started (`codex exec`) runs on its own harness, not the chat's: its mark
  // shows; one of the chat's own family keeps the toned subagent mark.
  const chat = useContext(SubagentHarnessContext);
  const harness = foreignHarness(agent.harness, chat, useSenderIconLook().badge);
  const { className, style } = waveProps(wave);
  return (
    <span
      className={className ? `cv-subagent-avatar ${className}` : "cv-subagent-avatar"}
      style={style}
      data-state={agent.state}
    >
      <AgentIdentity harness={harness} tone={agentTone(agent.id)} size={14} fallback={SUBAGENT_FALLBACK} />
    </span>
  );
}

/// The group's one line (Leo 2026-10-13): "1 subagent", "3 subagents done", or the count and what
/// differs, "2 subagents, 1 failed" (and any stopped; done ones once none run). Running is the default
/// state and the mark already says it, so it is never worded (Leo, 2026-11-23: "it's running or it's
/// failed or it's done").
/// Each count takes the pane language's plural form.
function groupLabel(t: Translate, language: PaneLanguage, agents: readonly Subagent[]): string {
  const n = agents.length;
  const count = (state: string) => agents.filter((agent) => agent.state === state).length;
  const [runningCount, failed, done] = [count("running"), count("failed"), count("completed")];
  // Stopped by the person (cancelled) or lost by acpmux (disconnected): ended, not failed.
  const stopped = count("cancelled") + count("disconnected");
  if (n > 0 && done === n) return t("subagents.allDone", { n });
  if (n > 0 && failed === n) return t("subagents.allFailed", { n });
  // Running is the default the mark carries; only the states that differ are worded, in the shared order.
  const states = orderedCountWords({ failed, stopped, done: runningCount === 0 ? done : 0 }, t);
  const total = t("subagents.count", { n });
  if (states.length === 0) return total;
  const list = intl.ListFormat(language, { type: "unit", style: "short" }).format(states);
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
      <GroupElapsed agents={agents} />
      <Icon name={expanded ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
    </button>
  );
}

/// One subagent in an open group: its avatar, name (in the agent's color,
/// agentTones.ts), state or current action with its workflow's agent counts (subagentProgress.ts, no tokens or tool uses), and time. `edge` rounds the list's first and last
/// rows. A click opens its own view; a running one has a stop button beside it. Its kind (Explore,
/// general-purpose) is no subtitle beside the name (Leo, 2026-10-31: "a lot of these subtitles are
/// bad"): the line's tooltip keeps it.
export function SubagentListRow({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const language = usePaneLanguage();
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const open = pane ?? nav;
  const stop = useContext(SubagentStopContext);
  const tones = useContext(AgentTonesContext);
  const actions = useContext(TurnActionsContext);
  const agent = row.subagents?.[0];
  if (!agent) return null;
  const label = STATE_LABEL[agent.state as keyof typeof STATE_LABEL] ?? STATE_LABEL.completed;
  const state = [
    // Running is the avatar's spinner, never a word (Leo, 2026-11-23): a bare shell step says nothing.
    running(agent) ? namedAction(t, agent.action, agent.actionShell) : t(label),
    ...subagentProgress(t, language, agent, { usage: false }),
  ]
    .filter(Boolean)
    .join(" · ");
  const content = (
    <>
      <Avatar agent={agent} />
      <span className="cv-subagent__text">
        <span className="cv-subagent__name">{subagentDisplayName(t, agent)}</span>
        <span className="cv-subagent__state">{state}</span>
      </span>
      <SubagentElapsed agent={agent} />
    </>
  );
  const kind = agent.kind && agent.kind !== agent.name && !isRepeatedAgentKind(agent.kind) ? agent.kind : undefined;
  const line = !open ? (
    <div
      id={row.id}
      className="cv-subagent"
      data-edge={row.status}
      data-agent-tone={tones?.get(agent.id)}
      // tooltip-allow: its kind, which the line no longer shows
      title={kind}
    >
      {content}
    </div>
  ) : (
    <button
      type="button"
      id={row.id}
      className="cv-subagent"
      data-edge={row.status}
      data-agent-tone={tones?.get(agent.id)}
      aria-label={t("subagents.open", { name: subagentDisplayName(t, agent) })}
      // tooltip-allow: its kind, which the line no longer shows
      title={kind}
      onClick={() => open(agent.id)}
    >
      {content}
      <Icon name="disclosure.collapsed" size={12} />
    </button>
  );
  // A stopped one offers Resume beside its line, as its end line does (ResumeControl.tsx).
  if (!running(agent) && actions.resumeAgent && canResume(agent, actions.retryCapabilities))
    return (
      <div className="cv-subagent-stoppable">
        {line}
        <ResumeControl agent={agent} actions={actions} />
      </div>
    );
  // An agent a shell call started stops with that call, not through Claude.
  if (!stop || !running(agent) || agent.command) return line;
  return (
    <div className="cv-subagent-stoppable">
      {line}
      <StopButton agent={agent} stop={stop} />
    </div>
  );
}

function GroupElapsed({ agents }: { agents: readonly Subagent[] }) {
  if (agents.length === 0) return <Elapsed since={0} until={0} clock="cv-subagents__time" />;
  const live = agents.some(ticking);
  const since = Math.min(...agents.map((agent) => agent.startedAt));
  const until = live ? undefined : Math.max(...agents.map((agent) => agent.endedAt ?? agent.startedAt));
  return <Elapsed since={since} until={until} clock="cv-subagents__time" />;
}

function SubagentElapsed({ agent }: { agent: Subagent }) {
  const time = subagentTime(agent, useNow(ticking(agent)));
  return time ? <Clock className="cv-subagent__time" text={time} /> : null;
}

/// A running subagent's stop button. It stays off while Claude has the request (and after Claude
/// takes it, until the subagent ends); when acpmux or Claude refuses, it says so and can be tried
/// again.
export function StopButton({
  agent,
  stop,
  solid = false,
}: {
  agent: Subagent;
  stop: (id: string) => Promise<unknown>;
  /// A filled square, as Claude Desktop's running rows draw it (the running tray's lines).
  solid?: boolean;
}) {
  const t = useT();
  const [state, setState] = useState<"idle" | "stopping" | "failed">("idle");
  const label = t(state === "failed" ? "subagents.stopFailed" : "subagents.stop", {
    name: subagentDisplayName(t, agent),
  });
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
      <Icon name="action.stop" size={12} selected={solid} />
    </button>
  );
}
