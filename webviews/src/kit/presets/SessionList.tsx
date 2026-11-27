/** @jsxImportSource ../closed */
// A closed file (tsconfig.closed.json): kit pieces only; no raw element, `style` or `className` compiles.
// A list of sessions built only from kit pieces (List, Row, Icon, StatusGlyph, Spinner, Pill),
// styled by a SessionLook. `MinimalSessions` is the minimal sidebar look (cmux#45143) on it: one
// line per session, its status first (a spinner while it works, its own mark when it is blocked,
// done or failed, nothing when idle), then its name. Status words never show in the row; they go
// to assistive tech through `statusLabel` (the sidebar spec: no routine status words in rows).
import type { ReactNode } from "react";
import { List } from "../List";
import { Row } from "../Row";
import { Pill } from "../Pill";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { StatusGlyph } from "../../ui/StatusGlyph";
import { MINIMAL_SESSIONS_LOOK, type SessionLook, type SessionState } from "./sessionLook";

export interface Session {
  id: string;
  name: string;
  state: SessionState;
  /** A cmux icon name: the harness or the workspace's own icon. */
  icon?: string;
  directory?: string;
  branch?: string;
  tabCount?: number;
  /** Already formatted for the person ("2m"). */
  lastActivity?: string;
}

export interface SessionListProps {
  sessions: readonly Session[];
  look: SessionLook;
  /** The state's words for assistive tech, in the page's language. */
  statusLabel(state: SessionState): string;
  title?: ReactNode;
  /** The accessible name when there is no title. */
  label?: string;
  selectedId?: string;
  onSelect?(id: string): void;
}

/** The status mark at the 12 px status size; idle draws nothing. Without detailed marks a row
 * still shows what needs the person (waiting, permission, error); only done goes unmarked. */
function statusMark(state: SessionState, detailed: boolean): ReactNode {
  if (state === "working") return <Spinner size={12} />;
  if (state === "idle" || (state === "done" && !detailed)) return null;
  return <StatusGlyph name={state} size={12} />;
}

export function SessionList({ sessions, look, statusLabel, title, label, selectedId, onSelect }: SessionListProps) {
  const leadingStatus = look["sidebar.workspaceRow.statusPlacement"] === "leading";
  return (
    <List title={title} label={label}>
      {sessions.map((session) => {
        const mark = statusMark(session.state, look["sidebar.detailedStatusIcons"]);
        const secondLine = [
          look["sidebar.workspaceRow.directory"] ? session.directory : undefined,
          look["sidebar.workspaceRow.branch"] ? session.branch : undefined,
        ].filter(Boolean);
        const showIcon = look["sidebar.workspaceRow.icon"] && session.icon !== undefined;
        const tabs = look["sidebar.workspaceRow.tabCount"] && (session.tabCount ?? 0) > 1;
        const time = look["sidebar.workspaceRow.lastActivity"] ? session.lastActivity : undefined;
        const trailing =
          !leadingStatus || tabs || time ? (
            <>
              {time}
              {tabs && <Pill size="sm">{session.tabCount}</Pill>}
              {!leadingStatus && mark}
            </>
          ) : undefined;
        return (
          <Row
            key={session.id}
            title={session.name}
            subtitle={secondLine.length > 0 ? secondLine.join(" · ") : undefined}
            // A leading status, or an icon column, keeps its place on rows that draw none, so every name
            // starts on one line.
            leading={
              leadingStatus ? (
                mark
              ) : showIcon ? (
                <Icon name={session.icon!} size={16} row />
              ) : look["sidebar.workspaceRow.icon"] ? null : undefined
            }
            trailing={trailing}
            density={look["sidebar.density"]}
            selected={session.id === selectedId}
            label={session.state === "idle" ? undefined : `${session.name}, ${statusLabel(session.state)}`}
            onSelect={onSelect ? () => onSelect(session.id) : undefined}
          />
        );
      })}
    </List>
  );
}

/** The minimal sidebar look (cmux#45143) on the kit. */
export function MinimalSessions(props: Omit<SessionListProps, "look">) {
  return <SessionList {...props} look={MINIMAL_SESSIONS_LOOK} />;
}
