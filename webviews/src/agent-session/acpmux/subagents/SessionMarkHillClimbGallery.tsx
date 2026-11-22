// l10n-allow-file: gallery fixtures, not shipped UI.
import type { ReactNode } from "react";
import { AgentMark } from "../../shared/AgentMark";
import { Icon } from "../icons/Icon";

/**
 * Which mark a session, subagent or notification row draws (hill-climb, 2026-11-22). Leo: "when did we
 * decide to omit the claude/codex or whatever icons and only do the diamonds? why diamonds? ... ay, go hill
 * climb this". Four answers side by side, each the same short transcript at row size: a thinking row and two
 * tool rows (the system the marks sit in), two subagents of this chat, and two messages from other sessions.
 *
 * (a) today: a row with no harness draws the sparkle (`task.ai`) alone in its tone; a sender with one draws
 *     its family's mark with the sparkle as a badge (senderIconLook.ts, the default).
 * (b) the harness's own mark everywhere; the tone stays on the name.
 * (c) the harness's mark, and a child of this chat wears a small branch badge in its tone.
 * (d) the harness's mark, and a child of this chat hangs under its parent on a hook, as Claude Code nests a
 *     tool's output under its call (⎿); a message from elsewhere sits at the left edge like any sender.
 */
export type SessionMarkScheme = "light" | "dark" | "paper" | "midnight";
export interface SessionMarkHillClimbProps {
  scheme: SessionMarkScheme;
}

type Look = "a" | "b" | "c" | "d";
type Row =
  | { kind: "tool"; icon: string; text: string }
  | { kind: "child" | "elsewhere"; harness?: "claude" | "codex"; tone: number; name: string; text: string };

const ROWS: Row[] = [
  { kind: "tool", icon: "tool.thought", text: "Thought for 12s" },
  { kind: "tool", icon: "tool.shell", text: "Ran bun test src/icons" },
  { kind: "tool", icon: "tool.read", text: "Read SenderIcon.tsx" },
  { kind: "tool", icon: "tool.group", text: "Started 2 agents" },
  { kind: "child", tone: 3, name: "Explore", text: "find the sparkle's history" },
  { kind: "child", harness: "codex", tone: 1, name: "review", text: "check the diff" },
  { kind: "elsewhere", harness: "claude", tone: 0, name: "polish-coordinator", text: "Take the digest row first." },
  { kind: "elsewhere", harness: "codex", tone: 4, name: "review-lane", text: "Review passed at e34ce27." },
];

const LOOKS: { look: Look; title: string; note: string }[] = [
  { look: "a", title: "(a) Today", note: "sparkle alone, or the mark with a sparkle badge" },
  { look: "b", title: "(b) Harness mark", note: "Claude or Codex, nothing else" },
  { look: "c", title: "(c) Mark + branch badge", note: "a child wears a small branch" },
  { look: "d", title: "(d) Mark + hook (pick)", note: "a child hangs under its parent" },
];

const SIZE = 16;
/// A row's harness: a subagent with none of its own runs on its chat's (this chat is Claude).
const CHAT_HARNESS = "claude";

/// A small branch, filled shapes for 7 px: two dots joined by a curve, in the child's tone.
function BranchBadge() {
  return (
    <svg className="session-mark__badge" viewBox="0 0 16 16" width={8} height={8} aria-hidden="true">
      <circle cx="4" cy="3.5" r="2.5" fill="currentColor" />
      <circle cx="12" cy="12.5" r="2.5" fill="currentColor" />
      <path d="M4 5v2.5a5 5 0 0 0 5 5h1" fill="none" stroke="currentColor" strokeWidth="2.25" strokeLinecap="round" />
    </svg>
  );
}

/// The sparkle as today's badge draws it: a filled four-point star.
function SparkleBadge() {
  return (
    <svg className="session-mark__badge" viewBox="0 0 16 16" width={9} height={9} aria-hidden="true">
      <path d="M8 .5Q8.9 7.1 15.5 8Q8.9 8.9 8 15.5Q7.1 8.9.5 8Q7.1 7.1 8 .5Z" fill="currentColor" />
    </svg>
  );
}

function Mark({ row, look }: { row: Extract<Row, { tone: number }>; look: Look }) {
  const harness = row.harness ?? (row.kind === "child" ? CHAT_HARNESS : undefined);
  if (look === "a") {
    if (!row.harness)
      return (
        <span data-agent-tone={row.tone} className="session-mark__toned">
          <Icon name="task.ai" size={SIZE} row />
        </span>
      );
    return (
      <span className="session-mark__slot">
        <AgentMark agent={row.harness} size={SIZE} />
        <span data-agent-tone={row.tone} className="session-mark__toned session-mark__corner">
          <SparkleBadge />
        </span>
      </span>
    );
  }
  const mark = <AgentMark agent={harness} size={look === "d" && row.kind === "child" ? 14 : SIZE} />;
  if (look === "c" && row.kind === "child")
    return (
      <span className="session-mark__slot">
        {mark}
        <span data-agent-tone={row.tone} className="session-mark__toned session-mark__corner">
          <BranchBadge />
        </span>
      </span>
    );
  return mark;
}

function Line({ row, look }: { row: Row; look: Look }) {
  if (row.kind === "tool")
    return (
      <div className="session-mark__row">
        <span className="session-mark__icon">
          <Icon name={row.icon} size={SIZE} row />
        </span>
        <span className="session-mark__text">{row.text}</span>
      </div>
    );
  const hooked = look === "d" && row.kind === "child";
  return (
    <div className="session-mark__row" data-hooked={hooked || undefined}>
      {hooked ? <span className="session-mark__hook" aria-hidden="true" /> : null}
      <span className="session-mark__icon">
        <Mark row={row} look={look} />
      </span>
      <span className="session-mark__text">
        <b data-agent-tone={row.tone} className="session-mark__toned">
          {row.name}
        </b>{" "}
        {row.text}
      </span>
    </div>
  );
}

export function SessionMarkHillClimb({ scheme }: SessionMarkHillClimbProps): ReactNode {
  return (
    <main className="session-mark acpmux-conversation" data-scheme={scheme} data-gallery-capture="">
      {LOOKS.map(({ look, title, note }) => (
        <figure key={look} className="session-mark__look" data-look={look}>
          <figcaption>
            {title}
            <small>{note}</small>
          </figcaption>
          {ROWS.map((row, index) => (
            <Line key={index} row={row} look={look} />
          ))}
        </figure>
      ))}
    </main>
  );
}
