// A finished turn's started sub-sessions, one line each, kept in sight once the turn's work folds
// (taskLines.ts): the task's harness mark, its title (what it is about, not its short name), its
// state, and a chevron after them; the whole line opens the task's chat, where its report is. As
// ChatGPT keeps "✓ Review October engineering work ›" under its fold (Leo, 2026-11-02: "see this
// is the kinda scenario we wanna be able to display super nicely"). A task still working draws no
// spinner (design/chat-transcript.md, "Grouped steps": no tool-call row draws one): its harness mark
// stays, and its title shimmers as a running tool row's words do (ShimmerText.tsx RowShimmer).
import { useContext } from "react";
import { useT } from "../i18n";
import { AgentIdentity } from "../subagents/AgentIdentity";
import { agentTone } from "../subagents/agentTones";
import { SubsessionContext, useSubsessionInfo } from "../subagents/subsessions";
import { AgentTag } from "./AgentTag";
import { AlertCircle, Check, Clock } from "./icons";
import { RowShimmer } from "./ShimmerText";
import type { StartedTask } from "./taskLineKind";
import { TranscriptActivityRow } from "./TranscriptActivityRow";
import "./TaskLine.css";
import { openSessionAttributes } from "./menuParts";

/// The harness mark's size: a received message's sender logo's (IncomingMessageCard.tsx), so every
/// agent mark in the transcript's icon column is one size.
const TASK_LOGO_SIZE = 12;

export function TaskLines({ tasks }: { tasks: readonly StartedTask[] }) {
  return (
    <div className="cv-tools cv-task-lines">
      {tasks.map((task) => (
        <TaskLine key={task.sessionId} task={task} />
      ))}
    </div>
  );
}

function TaskLine({ task }: { task: StartedTask }) {
  const t = useT();
  const live = useSubsessionInfo(task.sessionId);
  const open = useContext(SubsessionContext)?.open;
  const title = live?.title ?? live?.name ?? task.name ?? task.sessionId;
  const state = live?.state ?? "done";
  const working = state === "working";
  const mark =
    state === "failed" ? <AlertCircle size={14} /> : state === "input" ? <Clock size={14} /> : <Check size={14} />;
  return (
    <TranscriptActivityRow
      icon={
        <AgentIdentity harness={live?.harness ?? task.harness} tone={agentTone(task.sessionId)} size={TASK_LOGO_SIZE} />
      }
      name={title}
      after={
        working ? (
          <RowShimmer>
            <AgentTag name={title} />
          </RowShimmer>
        ) : (
          <span
            className="cv-task-line__state"
            /* tooltip-allow: the mark alone shows the state; its word is the tooltip */
            title={state === "done" ? t("subagents.state.completed") : undefined}
          >
            {mark}
          </span>
        )
      }
      className={`cv-task-line${working ? " is-live" : ""}`}
      ariaLabel={title}
      attributes={{
        "data-task-line": state,
        "data-session-id": task.sessionId,
        ...(open ? openSessionAttributes(task.sessionId) : {}),
      }}
      onClick={open ? () => open(task.sessionId) : undefined}
    />
  );
}
