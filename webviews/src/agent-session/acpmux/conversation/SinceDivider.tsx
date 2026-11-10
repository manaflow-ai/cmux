// The unread marker (design/transcript-overlays.md). Leo, 2026-11-10: "you can take a lot of
// inspiration from, say, like [other chat apps] ... make it look integrated". The static view,
// `SinceDivider`: where the person left a chat that kept working (acpmux `seenSeq`, `hub/seen.rs`), a
// hairline in the theme's accent across the text column with a small "New" tag pinned to its end, as
// chat apps draw it. Its row keeps the transcript's 28px rhythm (model.ts), placed when the chat opens
// and kept until another chat is selected, so it never appears or goes under the reader. Once read it
// fades in place: the row stays, nothing moves. The recap the daemon made for the same return
// (`hub/away_recap.rs`) draws under it.
//
// The way to it is the transcript's one jump control (VirtualTranscript.tsx JumpToLatest,
// jumpControl.ts): while the line is above the view and unreached, the control points up with the
// count of new turns. Leo, 2026-11-10: "There's also no point doubling up on this."
//
// Every shape, colour and motion is a token (unread.css; check-design-tokens.ts TOKEN_ONLY_FILES).
import { useCallback, useSyncExternalStore } from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { setUnreadBannerMode, useUnreadBannerMode } from "../chatDisplay";
import { useT } from "../i18n";
import type { AcpmuxSince } from "../model";
import { RecapNote } from "./RecapNote";
import {
  markUnreadRead,
  noteUnreadMounted,
  noteUnreadSide,
  readUnread,
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
