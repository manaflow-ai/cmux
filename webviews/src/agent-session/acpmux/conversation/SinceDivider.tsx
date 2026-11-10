// "New since you looked": when the person comes back to a chat that kept working, a line marks
// where they left off (acpmux `seenSeq`, `hub/seen.rs`), with how many turns ended since. The recap
// the daemon made for the same return (`hub/away_recap.rs`) draws under it, so the two never say
// the same thing twice (Leo, 2026-11-08: "go think of things/look at things, esp valuable things
// that people would think \"wow this is awesome\""). The row is placed when the chat opens and stays
// until another chat is selected, so it never appears or goes under the reader.
//
// Drawn the way team chat apps draw their unread line, in the pane's own accent (Leo, 2026-11-10:
// "the line is weird and the placement is weird ... I'm not even sure if it's themed ... make it
// look integrated"): a hairline across the text column that ends in
// a small filled New tag, the turn count muted before it. Jump to new over the top is a glass bar
// on the same column. Both follow the viewer's pick (sinceView.ts): expanded, collapsed (a click on
// the line, or the right-click) or hidden (the right-click; the chat menu shows it again).
import { useCallback, useSyncExternalStore } from "react";
import type { ContextMenuItem } from "../../../ui/ContextMenu";
import { ContextMenu } from "../../../ui/ContextMenu";
import { type Translate, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxSince } from "../model";
import { RecapNote } from "./RecapNote";
import { ArrowDown } from "./icons";
import { setSinceView, type SinceViewPick, useSinceView } from "./sinceView";

/// Where the drawn line is from the reader (`SinceJump`): on screen, above or below the view. The
/// virtual transcript drops a row far from the view, so a line not drawn keeps the side it left by
/// (above at first: a chat opens at its latest message). `seen`: the line was on screen once, after
/// which Jump to new has done its job and stays away for that mark.
type SinceView = { mark: string; side: "in" | "above" | "below"; seen: boolean };
let view: SinceView | undefined;
const listeners = new Set<() => void>();
function setView(next: SinceView | undefined): void {
  if (view?.mark === next?.mark && view?.side === next?.side && view?.seen === next?.seen) return;
  view = next;
  for (const listener of listeners) listener();
}
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const readView = () => view;

/// Follows the drawn line's place in the transcript's scroller with one IntersectionObserver, which
/// goes with the row (a ref callback's cleanup): nothing runs per scroll frame.
function useSinceObserver(mark: string) {
  return useCallback(
    (node: HTMLElement | null) => {
      if (!node) return;
      const root = node.closest(".acpmux-scroll");
      if (view?.mark !== mark) setView({ mark, side: "above", seen: false });
      const observer = new IntersectionObserver(
        ([entry]) => {
          if (!entry) return;
          const box = entry.rootBounds;
          const side = entry.isIntersecting
            ? "in"
            : box && entry.boundingClientRect.bottom <= box.top
              ? "above"
              : "below";
          setView({ mark, side, seen: (view?.mark === mark && view.seen) || side === "in" });
        },
        { root: root instanceof HTMLElement ? root : null },
      );
      observer.observe(node);
      return () => observer.disconnect();
    },
    [mark],
  );
}

/// The right-click of the line and of Jump to new: expanded or collapsed (a checked pick every chat
/// follows), then Hide. The chat menu's Show New Since You Looked brings a hidden one back.
function sinceMenu(pick: SinceViewPick, t: Translate): ContextMenuItem[] {
  return [
    {
      id: "since-expanded",
      label: t("since.menu.expanded"),
      checked: pick === "expanded",
      onSelect: () => setSinceView("expanded"),
    },
    {
      id: "since-collapsed",
      label: t("since.menu.collapsed"),
      checked: pick === "collapsed",
      onSelect: () => setSinceView("collapsed"),
    },
    {
      id: "since-hide",
      label: t("since.menu.hide"),
      separatorBefore: true,
      onSelect: () => setSinceView("hidden"),
    },
  ];
}

export function SinceDivider({
  since,
  onDismissRecap,
  view,
}: {
  since: AcpmuxSince;
  /// The recap's ×. Without it (a read-only transcript) the recap draws no ×.
  onDismissRecap?: () => void;
  /// A pick shown over the viewer's own (a gallery stage).
  view?: SinceViewPick;
}) {
  const t = useT();
  const stored = useSinceView();
  const pick = view ?? stored;
  const observe = useSinceObserver(since.key);
  // Hidden draws nothing, so the row takes no room (model.ts estimates it at 0).
  if (pick === "hidden") return null;
  const expanded = pick === "expanded";
  const turns = t("since.turns", { n: since.turns });
  return (
    <div className="cv-since" data-view={pick} ref={observe}>
      <ContextMenu className="cv-since__menu" items={sinceMenu(pick, t)}>
        <button
          type="button"
          className="cv-since__line"
          aria-expanded={expanded}
          aria-label={`${t("since.label")}, ${turns}`}
          onClick={() => setSinceView(expanded ? "collapsed" : "expanded")}
        >
          <span className="cv-since__rule" aria-hidden="true" />
          {expanded && (
            <span className="cv-since__count" aria-hidden="true">
              {turns}
            </span>
          )}
          <span className="cv-since__tag" aria-hidden="true">
            {t("since.tag")}
          </span>
        </button>
      </ContextMenu>
      {expanded && since.recap && <RecapNote recap={since.recap} onDismiss={onDismissRecap} lead={false} />}
    </div>
  );
}

/// Jump to new: a glass bar over the transcript's top, on the text column, while "New since you
/// looked" is out of view and the reader has not reached it yet; collapsed, a small New tab. Mounted
/// with the line's mark and only faded (conversation.css), so it never pops in; `onJump` brings the
/// line in (App.tsx, the transcript's row reveal). Its × puts it away for this return only.
export function SinceJump({
  mark,
  turns,
  onJump,
  view,
}: {
  mark: string;
  /// The turns that ended since, when the transcript knows them (model.ts `sinceTurns`).
  turns?: number;
  onJump: () => void;
  view?: SinceViewPick;
}) {
  const t = useT();
  const stored = useSinceView();
  const pick = view ?? stored;
  const where = useSyncExternalStore(subscribe, readView, readView);
  if (pick === "hidden") return null;
  const mine = where?.mark === mark ? where : undefined;
  const shown = !mine?.seen && mine?.side !== "in";
  const expanded = pick === "expanded";
  const label = t("since.label");
  const count = turns !== undefined ? t("since.turns", { n: turns }) : undefined;
  return (
    <ContextMenu className="acpmux-since-jump-host" items={sinceMenu(pick, t)}>
      <div
        className="ui-glass acpmux-since-jump"
        data-view={pick}
        data-shown={shown ? "" : undefined}
        data-side={mine?.side === "below" ? "below" : "above"}
        inert={!shown}
      >
        <button
          type="button"
          className="acpmux-since-jump__go"
          aria-label={[t("since.jump"), label, count].filter(Boolean).join(", ")}
          onClick={onJump}
        >
          <span className="acpmux-since-jump__arrow" aria-hidden="true">
            <ArrowDown size={12} />
          </span>
          {expanded ? (
            <span className="acpmux-since-jump__text" aria-hidden="true">
              <span className="acpmux-since-jump__label">{label}</span>
              {count && <span className="acpmux-since-jump__count">{count}</span>}
            </span>
          ) : (
            <span className="cv-since__tag" aria-hidden="true">
              {t("since.tag")}
            </span>
          )}
        </button>
        {expanded && (
          <button
            type="button"
            className="acpmux-since-jump__dismiss"
            aria-label={t("since.dismiss")}
            onClick={() => setView({ mark, side: mine?.side ?? "above", seen: true })}
          >
            <Icon name="action.close" size={12} />
          </button>
        )}
      </div>
    </ContextMenu>
  );
}
