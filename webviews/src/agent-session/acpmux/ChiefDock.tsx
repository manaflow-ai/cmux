import { useMemo, useRef, useState, type CSSProperties, type KeyboardEvent } from "react";
import { Icon } from "./icons/Icon";
import { type StringKey, useT } from "./i18n";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { KeyboardScope } from "../../ui/KeyboardScope";
import { SenderIdentityLabel } from "./SenderIdentityLabel";
import { resolveSenderIdentity } from "./senderIdentity";
import {
  activityTime,
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
  | "fox"
  | "mochi";

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
  mochi: new URL("./mascots/ChiefMascotMochi.png", import.meta.url).href,
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
type ChiefStatus = "streaming" | "attention" | "error" | "complete" | "unread" | "idle";

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
  if (session.indicator === "done") return "complete";
  if (mark === "input") return "attention";
  if (mark === "error") return "error";
  if (mark === "running") return "streaming";
  if (mark === "unread") return "unread";
  return "idle";
};

const STATUS_ICONS: Record<Exclude<ChiefStatus, "idle" | "attention">, string> = {
  streaming: "status.running",
  error: "status.disconnected",
  complete: "status.complete",
  unread: "status.dot",
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
  const mascotButton = useRef<HTMLButtonElement>(null);
  const ranked = useMemo(
    () =>
      withoutChildren(sessions.filter(listed)).sort(
        (left, right) =>
          urgency(right, right.sessionId === currentId) - urgency(left, left.sessionId === currentId) ||
          (activityTime(right) ?? 0) - (activityTime(left) ?? 0),
      ),
    [currentId, sessions],
  );
  const cards = ranked.slice(0, MAX_CARDS);
  // Every chat that waits counts, also one past the four cards drawn.
  const attention = ranked.filter((session) => urgency(session, session.sessionId === currentId) >= 4).length;
  const cardsRef = useRef<HTMLDivElement>(null);
  // Folding makes the cards inert: focus on one of them (a card's close, Escape) moves to the
  // mascot instead of dropping to the page.
  const fold = () => {
    const active = cardsRef.current?.ownerDocument.activeElement;
    setExpanded(false);
    if (active && cardsRef.current?.contains(active)) mascotButton.current?.focus();
  };
  // Escape folds an open dock; a folded one leaves Escape to the window (the Quick Composer closes
  // on it). Like useEscapeToDismiss, a modified Escape or one that ends an IME composition is not it.
  const foldOnEscape = (event: KeyboardEvent) => {
    if (event.key !== "Escape" || !expanded) return;
    if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey || event.nativeEvent.isComposing) return;
    // A card's context menu is a portal: its Escape closes the menu, not the dock.
    if (!event.currentTarget.contains(event.target as Node)) return;
    event.preventDefault();
    event.stopPropagation();
    fold();
    mascotButton.current?.focus();
  };
  return (
    <aside
      className="acpmux-chief-dock"
      data-attached={attached}
      data-expanded={expanded}
      data-attention={attention > 0 ? "true" : undefined}
      aria-label={t("header.agentChat")}
    >
      {/* Escape from any control inside folds the dock (ui/KeyboardScope keeps the key wiring in ui/). */}
      <KeyboardScope className="acpmux-chief-dock-keys" handleKeyDown={foldOnEscape}>
        {/* Folded, the deck is a picture of the chats: inert, so none of its buttons is a Tab stop. */}
        <div ref={cardsRef} className="acpmux-chief-dock-cards" aria-hidden={!expanded} inert={!expanded}>
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
                  symbol: "link.open.newtab",
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
                      <span className="acpmux-chief-card-copy">
                        <strong>
                          {cardStatus !== "idle" && (
                            <span className="acpmux-chief-dock-status" data-status={cardStatus} aria-hidden="true">
                              {cardStatus === "attention" ? (
                                // The one Needs you mark (needsYou/needsYou.css), as the sidebar draws it.
                                <span className="acpmux-needs-you-dot" />
                              ) : (
                                <Icon name={STATUS_ICONS[cardStatus]} size={20} row />
                              )}
                            </span>
                          )}
                          <span className="acpmux-chief-card-title">
                            <SenderIdentityLabel
                              identity={{ ...resolveSenderIdentity({ name: title }, session, currentId), name: title }}
                              describe={false}
                            />
                          </span>
                        </strong>
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
                        <Icon name="link.open.newtab" size={20} />
                      </button>
                    </div>
                    <button
                      type="button"
                      className="acpmux-chief-card-dismiss"
                      aria-label={t("render.collapse")}
                      onClick={fold}
                    >
                      <Icon name="action.close" size={20} />
                    </button>
                  </article>
                </ContextMenu>
              );
            })}
          </div>
        </div>
        <div className="acpmux-chief-dock-mascot-wrap">
          <button
            ref={mascotButton}
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
              aria-label={t("chiefDock.detach")}
              aria-pressed={!attached}
              onClick={() => setAttached((value) => !value)}
            >
              <Icon name="link.open.newtab" size={20} />
            </button>
            <button
              type="button"
              className="acpmux-chief-dock-tool"
              aria-label={expanded ? t("render.collapse") : t("render.expand")}
              aria-expanded={expanded}
              onClick={() => setExpanded((value) => !value)}
            >
              <Icon name="disclosure.collapsed" size={20} className="acpmux-chief-dock-collapse-mark" />
            </button>
          </div>
        </div>
      </KeyboardScope>
    </aside>
  );
}
