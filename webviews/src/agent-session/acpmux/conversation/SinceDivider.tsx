// The unread marker (design/transcript-overlays.md). Leo, 2026-11-10: "you can take a lot of
// inspiration from, say, like [other chat apps] ... make it look integrated". Two parts:
//
// - The static view, `SinceDivider`: where the person left a chat that kept working (acpmux
//   `seenSeq`, `hub/seen.rs`). Leo, 2026-11-22, on a full-width rule and a "New" pill over a
//   subagent's "started working": "this is a bad new. it shouldnt just do this like this when
//   there's nothing. we need to have better focus/unfocus and dissipation. and probably also not
//   layout shift this. we can maybe even integrate the line into the worked for line area." So:
//   - it draws only when something new to read is under it (sinceNews.ts; the transcript says,
//     unreadState.ts `quiet`), and never over rows a reader at the pane already had in front of
//     them (`inPlace`: a return by hand to a chat left on screen, the line in view at once);
//   - its row takes no height: the mark lies over the gap between the rows it splits (its look,
//     sinceLook.experiment.ts), so it never moves a row when it comes, fades or goes;
//   - it fades in, and dissipates (fades and narrows) once a reader at the pane, in a focused
//     window, has had it on screen for SINCE_DWELL_MS; unfocused, it holds;
//   - it says how much came: "157 new messages", centered on the thin line's rule and at the end
//     of the Worked for rule (Leo, 2026-11-15, of the terminal chat's rule: "we needto properly do
//     somthing like this in the gui somehow"). The count is the news under it (sinceNews.ts
//     `sinceCount`), follows new rows while unread and freezes once read; only its words change.
//   The recap the daemon made for the same return (`hub/away_recap.rs`) draws under it, as content.
// - The moving view, `UnreadBanner`: "3 new turns since 3:42 · Mark read" in the transcript's
//   top-start zone (overlayLayout.ts) while the line is off screen, as chat apps' unread bars.
//   Expanded or collapsed to a small pill, hidden until the next return by Mark read, or off from
//   its right-click (the `agentPane.display.unreadBanner` setting); the line's right-click brings
//   it back. A quiet mark has none.
//
// Every shape, colour and motion is a token (unread.css; check-design-tokens.ts TOKEN_ONLY_FILES).
import { useCallback, useSyncExternalStore, useEffect, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { setUnreadBannerMode, useSessionRecapOn, useUnreadBannerMode } from "../chatDisplay";
import { useT } from "../i18n";
import type { AcpmuxSince } from "../model";
import { RecapNote } from "./RecapNote";
import { ArrowDown, ChevronLeft, ChevronRight } from "./icons";
import { pageAttention } from "../attention";
import {
  bannerShown,
  markUnreadRead,
  noteUnreadMounted,
  noteUnreadSide,
  readUnread,
  sinceDone,
  subscribeUnread,
  type UnreadBannerMode,
  dissipateUnread,
  type UnreadView,
  unreadShows,
} from "./unreadState";
import { sinceLook } from "./sinceLook.experiment";
import { SINCE_COUNT_CAP } from "./sinceNews";
import "./unread.css";
import { intl } from "../../../ui/intl";

export { sinceDone } from "./unreadState";

const useUnreadView = () => useSyncExternalStore(subscribeUnread, readUnread, readUnread);

/// Follows the drawn line's place in the transcript's scroller with one IntersectionObserver, which
/// goes with the row (a ref callback's cleanup): nothing runs per scroll frame.
/// `inPlace`: the line marks a return to a chat left on screen (unreadState.ts `noteUnreadSide`).
/// The node is the zero-height row; the observer reads its drawn mark, which lies over the gap.
function useSinceObserver(mark: string, inPlace: boolean) {
  return useCallback(
    (node: HTMLElement | null) => {
      if (!node) return;
      const root = node.closest(".acpmux-scroll");
      const target = node.querySelector(".cv-since__line") ?? node;
      noteUnreadMounted(mark);
      const observer = new IntersectionObserver(
        ([entry]) => {
          if (!entry) return;
          const box = entry.rootBounds;
          noteUnreadSide(
            mark,
            entry.isIntersecting ? "in" : box && entry.boundingClientRect.bottom <= box.top ? "above" : "below",
            inPlace,
          );
        },
        { root: root instanceof HTMLElement ? root : null },
      );
      observer.observe(target);
      return () => observer.disconnect();
    },
    [mark, inPlace],
  );
}

/// How long the line stays on screen to a reader at the pane before it dissipates: long enough to
/// see where they left off, short enough that it is gone by the time they read on.
export const SINCE_DWELL_MS = 3000;

/// Whether a reader is at the pane: the page shows, its window has focus and their hand was on it
/// lately (attention.ts). Unfocused or away, the line holds.
function readerAtPane(): boolean {
  if (typeof document === "undefined") return false;
  return document.visibilityState !== "hidden" && document.hasFocus() && (pageAttention()?.present() ?? true);
}

/// Follows `readerAtPane` while `on`: the page's visibility, the window's focus and the reader's
/// attention. Nothing is listened to while the line is not on screen.
function useReaderAtPane(on: boolean): boolean {
  const [here, setHere] = useState(false);
  useEffect(() => {
    if (!on) return undefined;
    const check = () => setHere(readerAtPane());
    check();
    const attention = pageAttention()?.subscribe(check);
    window.addEventListener("focus", check);
    window.addEventListener("blur", check);
    document.addEventListener("visibilitychange", check);
    return () => {
      attention?.();
      window.removeEventListener("focus", check);
      window.removeEventListener("blur", check);
      document.removeEventListener("visibilitychange", check);
    };
  }, [on]);
  return on && here;
}

/// Dissipates the line once it has been on screen to a reader at the pane for SINCE_DWELL_MS. The
/// clock starts over when they look away, unfocus the window or scroll it off.
function useDissipate(mark: string, onScreen: boolean, dwellMs: number): void {
  const here = useReaderAtPane(onScreen);
  useEffect(() => {
    if (!here) return undefined;
    const timer = setTimeout(() => dissipateUnread(mark), dwellMs);
    return () => clearTimeout(timer);
  }, [here, mark, dwellMs]);
}

/// How the line is drawn (sinceLook.experiment.ts); the gallery compares them.
export type SinceLook = "line" | "worked" | "pill";

/// The count as the label shows it: "999+" past the cap.
const shownCount = (count: number): number | string => (count > SINCE_COUNT_CAP ? `${SINCE_COUNT_CAP}+` : count);

/// "157 new messages", "999+ new messages" past the count's cap.
export function newMessagesLabel(t: ReturnType<typeof useT>, count: number): string {
  return t("since.messages", { n: shownCount(count) });
}

/// The line's count for `mark`: the gallery's, else the transcript's (unreadState.ts `count`).
/// Undefined (the label reads "New") before the rows are counted or past the count's reach.
const countOf = (mark: string, unread: UnreadView | undefined, forced?: number): number | undefined =>
  forced ?? (unread?.mark === mark && unread.count ? unread.count : undefined);

/// The banner and the line share one menu shape: what the reader can do with the unread marker.
function unreadMenu(
  t: ReturnType<typeof useT>,
  mark: string,
  mode: UnreadBannerMode,
  extra: ContextMenuItem[] = [],
): ContextMenuItem[] {
  return [
    ...extra,
    {
      id: "unread.markRead",
      label: t("since.markRead"),
      onSelect: () => markUnreadRead(mark),
    },
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
  look,
  read,
  dwellMs = SINCE_DWELL_MS,
  count: forcedCount,
}: {
  since: AcpmuxSince;
  /// The recap's ×. Without it (a read-only transcript) the recap draws no ×.
  onDismissRecap?: () => void;
  /// The gallery's look; the transcript draws the experiment's arm.
  look?: SinceLook;
  /// The gallery's read state; the transcript reads its own (unreadState.ts).
  read?: boolean;
  /// The gallery's dwell (a long one holds a still capture).
  dwellMs?: number;
  /// The gallery's count of new messages; the transcript's comes from its rows (unreadState.ts).
  count?: number;
}) {
  const t = useT();
  const unread = useUnreadView();
  const mode = useUnreadBannerMode();
  const recapOn = useSessionRecapOn();
  // Off in Settings (Session Recap), the recap draws nothing unless the chat's own option is on.
  const recap = since.recap && (recapOn || since.recap.chatOn) ? since.recap : undefined;
  const mine = unread?.mark === since.key ? unread : undefined;
  // Drawn once its observer answered (a line on screen at a return in place is read by then, so it
  // never flashes), while something new is under it and it is not read.
  const shows = read !== undefined ? !read : mine?.placed === true && unreadShows(since.key, unread);
  useDissipate(since.key, read === undefined && shows && mine?.side === "in", dwellMs);
  const label = t("since.label");
  const drawn = look ?? experimentArm(sinceLook);
  const count = countOf(since.key, unread, forcedCount);
  // The words on a look with a rule; the pill keeps its one word.
  const words = count !== undefined && drawn !== "pill" ? newMessagesLabel(t, count) : undefined;
  return (
    <div
      className="cv-since"
      data-look={drawn}
      data-shown={shows ? "" : undefined}
      data-recap={recap ? "" : undefined}
      ref={useSinceObserver(since.key, since.inPlace === true)}
    >
      <ContextMenu items={unreadMenu(t, since.key, mode)} className="cv-since__menu">
        <p
          className="cv-since__line"
          aria-label={words ?? `${label}, ${t("since.turns", { n: since.turns })}`}
          aria-hidden={shows ? undefined : true}
        >
          {drawn !== "pill" && <span className="cv-since__rule" aria-hidden="true" />}
          {drawn === "line" && words !== undefined && (
            <>
              <span className="cv-since__words" aria-hidden="true">
                {words}
              </span>
              <span className="cv-since__rule cv-since__rule--end" aria-hidden="true" />
            </>
          )}
          {drawn !== "line" && (
            // Both forms stack in one cell at the line's end (unread.css): the words where the row
            // has room, "New" where it is tight, so a resize cross-fades between them in place and
            // never wraps the tag to a second row or moves the rule.
            <span className="cv-since__tag" aria-hidden="true" data-words={words !== undefined ? "" : undefined}>
              {words !== undefined && <span className="cv-since__tag-words">{words}</span>}
              <span className="cv-since__tag-new">{t("since.new")}</span>
            </span>
          )}
        </p>
      </ContextMenu>
      {recap && <RecapNote recap={recap} onDismiss={onDismissRecap} lead={false} />}
    </div>
  );
}

let clock: Intl.DateTimeFormat | undefined;
/// 3:42 PM, in the person's locale.
const clockLabel = (at: number) =>
  (clock ??= intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit",
  })).format(new Date(at));

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
  count: forcedCount,
}: {
  mark: string;
  turns: number;
  /// When the first unread message arrived, ms; the banner says "since" it.
  firstNewAt?: number;
  onJump: () => void;
  /// The gallery's mode and shown state; the transcript reads the setting and the line's place.
  mode?: UnreadBannerMode;
  forceShown?: boolean;
  /// The gallery's count of new messages; the transcript's is the line's (unreadState.ts).
  count?: number;
}) {
  const t = useT();
  const unread = useUnreadView();
  const setting = useUnreadBannerMode();
  const mode = forcedMode ?? setting;
  if (mode === "off") return null;
  const mine = unread?.mark === mark ? unread : undefined;
  const shown = forceShown ?? bannerShown(mark, unread, mode);
  const collapsed = mode === "collapsed";
  // The line's count when it has one ("157 new messages"), else the turns acpmux counted.
  const messages = countOf(mark, unread, forcedCount);
  const count = messages !== undefined ? newMessagesLabel(t, messages) : t("since.bannerCount", { n: turns });
  const short = messages !== undefined ? shownCount(messages) : turns;
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
        {/* tooltip-allow: the jump shows an arrow and a count, never what it does; its tooltip names it */}
        <button type="button" className="acpmux-since-jump__body" title={t("since.jump")} onClick={jump}>
          <span className="acpmux-since-jump__arrow" aria-hidden="true">
            <ArrowDown size={12} />
          </span>
          <span className="acpmux-since-jump__count">{collapsed ? short : count}</span>
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
