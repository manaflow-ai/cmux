// The unread marker (design/transcript-overlays.md). Leo, 2026-11-10: "you can take a lot of
// inspiration from, say, like [other chat apps] ... make it look integrated". Two parts:
//
// - The static view, `SinceDivider`: where the person left a chat that kept working (acpmux
//   `seenSeq`, `hub/seen.rs`), a hairline in the theme's accent across the text column with a small
//   "New" tag pinned to its end, as chat apps draw it. Its row keeps the transcript's 28px rhythm
//   (model.ts), placed when the chat opens and kept until another chat is selected, so it never
//   appears or goes under the reader. Once read it fades in place: the row stays, nothing moves.
//   The recap the daemon made for the same return (`hub/away_recap.rs`) draws under it.
// - The moving view, `UnreadBanner`: "3 new turns since 3:42 · Mark read" in the transcript's
//   top-start zone (overlayLayout.ts) while the line is off screen, as chat apps' unread bars.
//   Expanded or collapsed to a small pill, hidden until the next return by Mark read, or off from
//   its right-click (the `agentPane.display.unreadBanner` setting); the line's right-click brings
//   it back.
//
// Every shape, colour and motion is a token (unread.css; check-design-tokens.ts TOKEN_ONLY_FILES).
import { useCallback, useSyncExternalStore } from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { setUnreadBannerMode, useUnreadBannerMode } from "../chatDisplay";
import { useT } from "../i18n";
import type { AcpmuxSince } from "../model";
import { RecapNote } from "./RecapNote";
import { ArrowDown, ChevronLeft, ChevronRight } from "./icons";
import {
  bannerShown,
  markUnreadRead,
  noteUnreadMounted,
  noteUnreadSide,
  readUnread,
  sinceDone,
  subscribeUnread,
  unreadRead,
  type UnreadBannerMode,
} from "./unreadState";
import "./unread.css";

export { sinceDone } from "./unreadState";

const useUnreadView = () => useSyncExternalStore(subscribeUnread, readUnread, readUnread);

/// Follows the drawn line's place in the transcript's scroller with one IntersectionObserver, which
/// goes with the row (a ref callback's cleanup): nothing runs per scroll frame.
function useSinceObserver(mark: string) {
  return useCallback(
    (node: HTMLElement | null) => {
      if (!node) return;
      const root = node.closest(".acpmux-scroll");
      noteUnreadMounted(mark);
      const observer = new IntersectionObserver(
        ([entry]) => {
          if (!entry) return;
          const box = entry.rootBounds;
          noteUnreadSide(
            mark,
            entry.isIntersecting ? "in" : box && entry.boundingClientRect.bottom <= box.top ? "above" : "below",
          );
        },
        { root: root instanceof HTMLElement ? root : null },
      );
      observer.observe(node);
      return () => observer.disconnect();
    },
    [mark],
  );
}

/// How the line is drawn; the gallery compares them. `tag` (chosen): the accent hairline with a
/// filled "New" tag at its end. `text`: the hairline with "New" in accent text at its end.
/// `labelled`: "New since you looked · 3 turns" leading the hairline (the first look,
/// on theme tokens).
export type SinceLook = "tag" | "text" | "labelled";

/// The banner and the line share one menu shape: what the reader can do with the unread marker.
function unreadMenu(
  t: ReturnType<typeof useT>,
  mark: string,
  mode: UnreadBannerMode,
  extra: ContextMenuItem[] = [],
): ContextMenuItem[] {
  return [
    ...extra,
    { id: "unread.markRead", label: t("since.markRead"), onSelect: () => markUnreadRead(mark) },
    mode === "off"
      ? {
          id: "unread.showBanner",
          label: t("since.showBanner"),
          separatorBefore: true,
          onSelect: () => setUnreadBannerMode("expanded"),
        }
      : {
          id: "unread.hideBanner",
          label: t("since.hideBanner"),
          separatorBefore: true,
          onSelect: () => setUnreadBannerMode("off"),
        },
  ];
}

export function SinceDivider({
  since,
  onDismissRecap,
  look = "tag",
  read,
}: {
  since: AcpmuxSince;
  /// The recap's ×. Without it (a read-only transcript) the recap draws no ×.
  onDismissRecap?: () => void;
  look?: SinceLook;
  /// The gallery's read state; the transcript reads its own (unreadState.ts).
  read?: boolean;
}) {
  const t = useT();
  const unread = useUnreadView();
  const mode = useUnreadBannerMode();
  const isRead = read ?? unreadRead(since.key, unread);
  const label = t("since.label");
  return (
    <div className="cv-since" data-look={look} data-read={isRead ? "" : undefined} ref={useSinceObserver(since.key)}>
      <ContextMenu items={unreadMenu(t, since.key, mode)} className="cv-since__menu">
        <p className="cv-since__line" aria-label={`${label}, ${t("since.turns", { n: since.turns })}`}>
          {look === "labelled" && (
            <span className="cv-since__lead" aria-hidden="true">
              <span className="cv-since__label">{label}</span>
              <span className="cv-since__count">{t("since.turns", { n: since.turns })}</span>
            </span>
          )}
          <span className="cv-since__rule" aria-hidden="true" />
          {look !== "labelled" && (
            <span className="cv-since__tag" aria-hidden="true">
              {t("since.new")}
            </span>
          )}
        </p>
      </ContextMenu>
      {since.recap && <RecapNote recap={since.recap} onDismiss={onDismissRecap} lead={false} />}
    </div>
  );
}

let clock: Intl.DateTimeFormat | undefined;
/// 3:42 PM, in the person's locale.
const clockLabel = (at: number) =>
  (clock ??= new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" })).format(new Date(at));

/// The moving view: in the transcript's top-start zone (VirtualTranscript.tsx places it from
/// overlayLayout.ts) while the "New" line is out of view and not yet reached. Mounted with the mark
/// and only faded (unread.css), so it never pops in. The body jumps to the line (`onJump`, App.tsx's
/// row reveal); Mark read fades the line and hides the banner until the next return; the chevron
/// collapses it to a pill or expands it, and keeps that as the setting.
/// Keeps `.acpmux-since-jump`, `data-shown` and `data-side` of the Jump to new pill it replaces, so
/// the browser tests of #40072 read it the same way.
export function UnreadBanner({
  mark,
  turns,
  firstNewAt,
  onJump,
  mode: forcedMode,
  forceShown,
}: {
  mark: string;
  turns: number;
  /// When the first unread message arrived, ms; the banner says "since" it.
  firstNewAt?: number;
  onJump: () => void;
  /// The gallery's mode and shown state; the transcript reads the setting and the line's place.
  mode?: UnreadBannerMode;
  forceShown?: boolean;
}) {
  const t = useT();
  const unread = useUnreadView();
  const setting = useUnreadBannerMode();
  const mode = forcedMode ?? setting;
  if (mode === "off") return null;
  const mine = unread?.mark === mark ? unread : undefined;
  const shown = forceShown ?? bannerShown(mark, unread, mode);
  const collapsed = mode === "collapsed";
  const count = t("since.bannerCount", { n: turns });
  const when = firstNewAt !== undefined ? t("since.bannerSince", { time: clockLabel(firstNewAt) }) : undefined;
  const jump = () => {
    // Pressed, it has done its job, also when the line's row is not drawn in view after the move.
    sinceDone(mark);
    onJump();
  };
  const toggle = () => setUnreadBannerMode(collapsed ? "expanded" : "collapsed");
  const items = unreadMenu(t, mark, mode, [
    { id: "unread.jump", label: t("since.jump"), onSelect: jump },
    {
      id: "unread.toggle",
      label: t(collapsed ? "since.expand" : "since.collapse"),
      onSelect: toggle,
    },
  ]);
  return (
    <ContextMenu items={items} asChild>
      <fieldset
        className="ui-glass acpmux-since-jump"
        aria-label={when ? `${count} ${when}` : count}
        data-shown={shown ? "" : undefined}
        data-side={mine?.side === "below" ? "below" : "above"}
        data-collapsed={collapsed ? "" : undefined}
        inert={!shown}
      >
        <button type="button" className="acpmux-since-jump__body" title={t("since.jump")} onClick={jump}>
          <span className="acpmux-since-jump__arrow" aria-hidden="true">
            <ArrowDown size={12} />
          </span>
          <span className="acpmux-since-jump__count">{collapsed ? turns : count}</span>
          <span className="acpmux-since-jump__more" aria-hidden={collapsed || undefined}>
            <span className="acpmux-since-jump__more-inner">
              {when && <span className="acpmux-since-jump__when">{when}</span>}
            </span>
          </span>
        </button>
        <span className="acpmux-since-jump__more" aria-hidden={collapsed || undefined}>
          <span className="acpmux-since-jump__more-inner">
            <button
              type="button"
              className="acpmux-since-jump__action"
              tabIndex={collapsed ? -1 : undefined}
              onClick={() => markUnreadRead(mark)}
            >
              {t("since.markRead")}
            </button>
          </span>
        </span>
        <button
          type="button"
          className="acpmux-since-jump__toggle"
          aria-label={t(collapsed ? "since.expand" : "since.collapse")}
          title={t(collapsed ? "since.expand" : "since.collapse")}
          onClick={toggle}
        >
          {collapsed ? <ChevronRight size={12} /> : <ChevronLeft size={12} />}
        </button>
      </fieldset>
    </ContextMenu>
  );
}
