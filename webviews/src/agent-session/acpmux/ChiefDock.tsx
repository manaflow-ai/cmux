import { useMemo, useState } from "react";
import { Icon } from "./icons/Icon";
import { useT } from "./i18n";
import { sessionTitle, sessionMark, type AcpmuxSessionEntry } from "./sessionList";

export type ChiefDockProps = {
  sessions: readonly AcpmuxSessionEntry[];
  currentId?: string;
  onSelect(sessionId: string): void;
  onNewChat(): void;
  onMoveToTab(sessionId: string): void;
};

const MAX_CARDS = 4;
const urgency = (session: AcpmuxSessionEntry): number => {
  switch (sessionMark(session, false)) {
    case "input":
      return 5;
    case "error":
      return 4;
    case "running":
      return 3;
    case "unread":
      return 2;
    default:
      return 1;
  }
};

const status = (session: AcpmuxSessionEntry): "streaming" | "attention" | "idle" => {
  const mark = sessionMark(session, false);
  if (mark === "input") return "attention";
  if (mark === "running") return "streaming";
  return "idle";
};

function StatusDot({ value }: { value: ReturnType<typeof status> }) {
  return <span className="acpmux-chief-dock-dot" data-status={value} aria-hidden="true" />;
}

/// A small, intentionally session-only dock. The native host can later make this a window-level
/// overlay; keeping the card model here means the first pass is useful in the Quick Composer and
/// in the component gallery without inventing a second session store.
export function ChiefDock({ sessions, currentId, onSelect, onNewChat, onMoveToTab }: ChiefDockProps) {
  const t = useT();
  const [attached, setAttached] = useState(true);
  const [expanded, setExpanded] = useState(true);
  const cards = useMemo(
    () =>
      sessions
        .filter((session) => !session.archived && !session.side)
        .sort((left, right) => urgency(right) - urgency(left) || (right.updatedAt ?? 0) - (left.updatedAt ?? 0))
        .slice(0, MAX_CARDS),
    [sessions],
  );
  const attention = cards.filter((session) => urgency(session) >= 4).length;
  return (
    <aside className="acpmux-chief-dock" data-attached={attached} data-expanded={expanded} aria-label={t("header.agentChat")}>
      <div className="acpmux-chief-dock-rail">
        <button
          type="button"
          className="acpmux-chief-dock-mascot"
          aria-label={t("header.agentChat")}
          title={t("header.agentChat")}
          onClick={() => setExpanded((value) => !value)}
        >
          <Icon name="agent.chief" size={19} />
          {attention > 0 && <span className="acpmux-chief-dock-badge">{attention}</span>}
        </button>
        <span className="acpmux-chief-dock-divider" aria-hidden="true" />
        <button type="button" className="acpmux-chief-dock-tool" aria-label={t("sidebar.newChat")} title={t("sidebar.newChat")} onClick={onNewChat}>
          <span aria-hidden="true">+</span>
        </button>
        <button
          type="button"
          className="acpmux-chief-dock-tool"
          aria-label={attached ? t("floating.moveToTab") : t("floating.keepOnTop")}
          title={attached ? t("floating.moveToTab") : t("floating.keepOnTop")}
          aria-pressed={attached}
          onClick={() => setAttached((value) => !value)}
        >
          <Icon name="action.pin" size={16} selected={attached} />
        </button>
      </div>
      {expanded && (
        <div className="acpmux-chief-dock-cards">
          <header className="acpmux-chief-dock-header">
            <span className="acpmux-chief-dock-title"><Icon name="agent.chief" size={14} /> {t("header.agentChat")}</span>
            <span className="acpmux-chief-dock-count">{cards.length}</span>
          </header>
          <div className="acpmux-chief-dock-stack">
            {cards.length === 0 && <p className="acpmux-chief-dock-empty">{t("sidebar.noSessions")}</p>}
            {cards.map((session, index) => {
              const selected = session.sessionId === currentId;
              const title = sessionTitle(session);
              return (
                <article className="acpmux-chief-card" data-selected={selected} data-depth={index} key={session.sessionId}>
                  <button type="button" className="acpmux-chief-card-main" onClick={() => onSelect(session.sessionId)}>
                    <StatusDot value={status(session)} />
                    <span className="acpmux-chief-card-copy">
                      <strong>{title}</strong>
                      <small>{session.preview || session.branch || session.cwd || t("sidebar.sessions")}</small>
                    </span>
                  </button>
                  <button
                    type="button"
                    className="acpmux-chief-card-open"
                    aria-label={t("floating.moveToTab")}
                    title={t("floating.moveToTab")}
                    onClick={() => onMoveToTab(session.sessionId)}
                  >
                    <Icon name="link.open.newtab" size={14} />
                  </button>
                </article>
              );
            })}
          </div>
        </div>
      )}
    </aside>
  );
}
