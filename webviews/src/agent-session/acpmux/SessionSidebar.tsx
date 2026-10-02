import React, { memo, useMemo, useState } from "react";
import { groupByProject, sessionMark, visibleSessions, type AcpmuxSessionEntry, type SessionMark } from "./sessionList";

const MARK_LABELS: Record<Exclude<SessionMark, undefined>, string> = { input: "Needs input", running: "Working", error: "Disconnected", unread: "New activity" };
const MARK_GLYPHS: Record<Exclude<SessionMark, undefined>, string> = { input: "?", running: "", error: "!", unread: "" };

/** The pane's session list: every acpmux session, grouped by folder, newest first. */
export function SessionSidebar({ sessions, selectedId, onSelect }: { sessions: AcpmuxSessionEntry[]; selectedId?: string; onSelect: (sessionId: string) => void }) {
  const groups = useMemo(() => groupByProject(sessions), [sessions]);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  return <nav className="acpmux-sidebar" id="acpmux-sidebar" aria-label="Sessions">{groups.length === 0 ? <div className="acpmux-sidebar-empty">No sessions yet</div> : groups.map((group) => {
    const { rows, hidden } = visibleSessions(group, expanded.has(group.key), selectedId);
    return <section className="acpmux-sidebar-group" key={group.key}><div className="acpmux-sidebar-project" title={group.cwd}>{group.label}</div><ul>{rows.map((session) => <SessionRow key={session.sessionId} session={session} selected={session.sessionId === selectedId} onSelect={onSelect} />)}</ul>{hidden > 0 && <button type="button" className="acpmux-sidebar-more" onClick={() => setExpanded((current) => new Set(current).add(group.key))}>Show {hidden} more</button>}</section>;
  })}</nav>;
}

const SessionRow = memo(function SessionRow({ session, selected, onSelect }: { session: AcpmuxSessionEntry; selected: boolean; onSelect: (sessionId: string) => void }) {
  const mark = sessionMark(session, selected);
  const title = session.displayTitle || session.sessionId.slice(0, 8);
  return <li><button type="button" className={`acpmux-session-row${selected ? " is-selected" : ""}${session.status === "closed" ? " is-closed" : ""}`} aria-current={selected ? "true" : undefined} aria-label={mark ? `${title}, ${MARK_LABELS[mark]}` : undefined} title={title} onClick={() => onSelect(session.sessionId)}><span className="acpmux-session-row-title">{title}</span>{mark && <span className={`acpmux-session-mark acpmux-session-mark-${mark}`} aria-hidden="true" title={MARK_LABELS[mark]}>{MARK_GLYPHS[mark]}</span>}</button></li>;
});
