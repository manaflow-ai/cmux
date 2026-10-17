import { useMemo, useState, type CSSProperties } from "react";
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

export type ChiefMascot =
  | "orb"
  | "orb-spark"
  | "orb-hood"
  | "machine"
  | "machine-cyan"
  | "machine-blue"
  | "moon"
  | "moon-blue"
  | "fox";

const CHIEF_MASCOTS: Record<ChiefMascot, string> = {
  orb: new URL("./mascots/ChiefMascotOrb.png", import.meta.url).href,
  "orb-spark": new URL("./mascots/ChiefMascotOrbSpark.png", import.meta.url).href,
  "orb-hood": new URL("./mascots/ChiefMascotOrbHood.png", import.meta.url).href,
  machine: new URL("./mascots/ChiefMascotMachine.png", import.meta.url).href,
  "machine-cyan": new URL("./mascots/ChiefMascotMachineCyan.png", import.meta.url).href,
  "machine-blue": new URL("./mascots/ChiefMascotMachineBlue.png", import.meta.url).href,
  moon: new URL("./mascots/ChiefMascotMoon.png", import.meta.url).href,
  "moon-blue": new URL("./mascots/ChiefMascotMoonBlue.png", import.meta.url).href,
  fox: new URL("./mascots/ChiefMascotFox.png", import.meta.url).href,
};

export type ChiefDockProps = {
  sessions: readonly AcpmuxSessionEntry[];
  currentId?: string;
  onSelect(sessionId: string): void;
  onNewChat(): void;
  onMoveToTab(sessionId: string): void;
  queueCounts?: ReadonlyMap<string, number>;
  steeringIds?: ReadonlySet<string>;
  mascot?: ChiefMascot;
  /** Keep the compact rail as the default; the gallery opts in to the open showcase state. */
  defaultExpanded?: boolean;
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
  mascot = "orb",
  defaultExpanded = false,
}: ChiefDockProps) {
  const t = useT();
  const [attached, setAttached] = useState(true);
  const [expanded, setExpanded] = useState(defaultExpanded);
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
      <div className="acpmux-chief-dock-cards" aria-hidden={!expanded}>
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
                popupClassName="acpmux-chief-card-context-menu"
                items={menuItems}
                targets="own"
              >
                <article
                  className="acpmux-chief-card"
                  data-selected={selected}
                  data-status={cardStatus}
                  data-steering={steering ? "true" : undefined}
                  data-depth={index}
                  style={{ "--chief-depth": index } as CSSProperties}
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
                    <span className="acpmux-chief-dock-dot" data-status={cardStatus} aria-hidden="true" />
                    <span className="acpmux-chief-card-copy">
                      <strong>{title}</strong>
                      <small>{session.preview || session.branch || session.cwd || t("sidebar.sessions")}</small>
                    </span>
                    {queued > 0 && <span className="acpmux-chief-card-queue">{queued}</span>}
                  </button>
                  <div className="acpmux-chief-card-actions">
                    <button
                      type="button"
                      className="acpmux-chief-card-action"
                      aria-label={t("floating.moveToTab")}
                      onClick={() => onMoveToTab(session.sessionId)}
                    >
                      <Icon name="action.go" size={18} />
                    </button>
                  </div>
                  <button
                    type="button"
                    className="acpmux-chief-card-dismiss"
                    aria-label={t("header.agentChat")}
                    onClick={() => setExpanded(false)}
                  >
                    <span aria-hidden="true">×</span>
                  </button>
                </article>
              </ContextMenu>
            );
          })}
        </div>
      </div>
      <div className="acpmux-chief-dock-mascot-wrap">
        <button
          type="button"
          className="acpmux-chief-dock-mascot"
          aria-label={t("header.agentChat")}
          aria-expanded={expanded}
          onClick={() => setExpanded((value) => !value)}
        >
          <img src={CHIEF_MASCOTS[mascot]} alt="" aria-hidden="true" />
          {attention > 0 && (
            <span className="acpmux-chief-dock-badge" aria-label={`${attention}`}>
              {attention}
            </span>
          )}
        </button>
        <div className="acpmux-chief-dock-rail">
          <button
            type="button"
            className="acpmux-chief-dock-tool"
            aria-label={t("sidebar.newChat")}
            onClick={onNewChat}
          >
            <Icon name="action.edit" size={20} />
          </button>
          <button
            type="button"
            className="acpmux-chief-dock-tool"
            aria-label={attached ? t("floating.moveToTab") : t("floating.keepOnTop")}
            aria-pressed={attached}
            onClick={() => setAttached((value) => !value)}
          >
            <span className="acpmux-chief-dock-wave" aria-hidden="true">
              <i />
              <i />
              <i />
              <i />
              <i />
            </span>
          </button>
          <button
            type="button"
            className="acpmux-chief-dock-tool"
            aria-label={expanded ? t("header.agentChat") : t("sidebar.newChat")}
            onClick={() => setExpanded((value) => !value)}
          >
            <Icon name="disclosure.collapsed" size={18} className="acpmux-chief-dock-collapse-mark" />
          </button>
        </div>
      </div>
    </aside>
  );
}
