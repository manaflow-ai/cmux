import { useMemo, useState } from "react";
import { Icon } from "./icons/Icon";
import { type StringKey, useT } from "./i18n";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import {
  listed,
  sessionTitle,
  sessionMark,
  type AcpmuxSessionEntry,
  type SessionMark,
  withoutChildren,
} from "./sessionList";

export type ChiefDockProps = {
  sessions: readonly AcpmuxSessionEntry[];
  currentId?: string;
  onSelect(sessionId: string): void;
  onNewChat(): void;
  onMoveToTab(sessionId: string): void;
  queueCounts?: ReadonlyMap<string, number>;
  steeringIds?: ReadonlySet<string>;
};

const MAX_CARDS = 4;
type ChiefStatus = "streaming" | "attention" | "error" | "idle";

const urgency = (session: AcpmuxSessionEntry, selected: boolean): number => {
  switch (sessionMark(session, selected)) {
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

const status = (session: AcpmuxSessionEntry, selected: boolean): ChiefStatus => {
  const mark = sessionMark(session, selected);
  if (mark === "input") return "attention";
  if (mark === "error") return "error";
  if (mark === "running") return "streaming";
  return "idle";
};

const MARK_LABELS: Record<Exclude<SessionMark, undefined>, StringKey> = {
  input: "sidebar.markInput",
  error: "sidebar.markError",
  running: "sidebar.markRunning",
  unread: "sidebar.markUnread",
};

function StatusDot({ value }: { value: ReturnType<typeof status> }) {
  return <span className="acpmux-chief-dock-dot" data-status={value} aria-hidden="true" />;
}

/// A small, intentionally session-only dock. The native host can later make this a window-level
/// overlay; keeping the card model here means the first pass is useful in the Quick Composer and
/// in the component gallery without inventing a second session store.
export function ChiefDock({
  sessions,
  currentId,
  onSelect,
  onNewChat,
  onMoveToTab,
  queueCounts,
  steeringIds,
}: ChiefDockProps) {
  const t = useT();
  const [attached, setAttached] = useState(true);
  const [expanded, setExpanded] = useState(true);
  const cards = useMemo(
    () =>
      withoutChildren(sessions.filter(listed))
        .sort(
          (left, right) =>
            urgency(right, right.sessionId === currentId) - urgency(left, left.sessionId === currentId) ||
            (right.updatedAt ?? 0) - (left.updatedAt ?? 0),
        )
        .slice(0, MAX_CARDS),
    [currentId, sessions],
  );
  const attention = cards.filter((session) => urgency(session, session.sessionId === currentId) >= 4).length;
  return (
    <aside
      className="acpmux-chief-dock"
      data-attached={attached}
      data-expanded={expanded}
      data-attention={attention > 0 ? "true" : undefined}
      aria-label={t("header.agentChat")}
    >
      <div className="acpmux-chief-dock-rail">
        <button
          type="button"
          className="acpmux-chief-dock-mascot"
          aria-label={t("header.agentChat")}
          aria-expanded={expanded}
          title={t("header.agentChat")}
          onClick={() => setExpanded((value) => !value)}
        >
          <Icon name="agent.chief" size={19} />
          {attention > 0 && <span className="acpmux-chief-dock-badge">{attention}</span>}
        </button>
        <span className="acpmux-chief-dock-divider" aria-hidden="true" />
        <button
          type="button"
          className="acpmux-chief-dock-tool"
          aria-label={t("sidebar.newChat")}
          title={t("sidebar.newChat")}
          onClick={onNewChat}
        >
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
      <div className="acpmux-chief-dock-cards" aria-hidden={!expanded}>
        <header className="acpmux-chief-dock-header">
          <span className="acpmux-chief-dock-title">
            <Icon name="agent.chief" size={14} /> {t("header.agentChat")}
          </span>
          <span className="acpmux-chief-dock-count">{cards.length}</span>
        </header>
        <div className="acpmux-chief-dock-stack">
          {cards.length === 0 && <p className="acpmux-chief-dock-empty">{t("sidebar.noSessions")}</p>}
          {cards.map((session, index) => {
            const selected = session.sessionId === currentId;
            const title = sessionTitle(session);
            const queued = queueCounts?.get(session.sessionId) ?? 0;
            const steering = steeringIds?.has(session.sessionId) === true;
            const mark = sessionMark(session, selected);
            const cardStatus = status(session, selected);
            const markLabel = mark ? t(MARK_LABELS[mark]) : undefined;
            const queueLabel = queued > 0 ? `${queued} ${t("composer.queued")}` : undefined;
            const menuItems: ContextMenuItem[] = [
              {
                id: "move-to-tab",
                label: t("floating.moveToTab"),
                icon: <Icon name="link.open.newtab" size={14} />,
                onSelect: () => onMoveToTab(session.sessionId),
              },
            ];
            return (
              <ContextMenu
                key={session.sessionId}
                className="acpmux-chief-card-menu-host"
                items={menuItems}
                targets="own"
              >
                <article
                  className="acpmux-chief-card"
                  data-selected={selected}
                  data-status={cardStatus}
                  data-steering={steering ? "true" : undefined}
                  data-depth={index}
                >
                  <button
                    type="button"
                    className="acpmux-chief-card-main"
                    aria-current={selected ? "true" : undefined}
                    aria-haspopup="menu"
                    aria-label={[title, markLabel, queueLabel].filter(Boolean).join(", ") || undefined}
                    disabled={!expanded}
                    onClick={() => onSelect(session.sessionId)}
                  >
                    <StatusDot value={cardStatus} />
                    <span className="acpmux-chief-card-copy">
                      <strong>{title}</strong>
                      <small>{session.preview || session.branch || session.cwd || t("sidebar.sessions")}</small>
                    </span>
                    {queued > 0 && <span className="acpmux-chief-card-queue">{queued}</span>}
                  </button>
                </article>
              </ContextMenu>
            );
          })}
        </div>
      </div>
    </aside>
  );
}
