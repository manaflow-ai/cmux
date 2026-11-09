import { type StringKey, type Translate, translate } from "./i18n";
import { ageWithDate } from "./timeLabels";
import { needsYouItems, type NeedsYouItem, type WatchedAsk } from "./needsYou/model";
import type { AttentionTab } from "./needsYou/attentionTabs";
import { activityTime, type AcpmuxSessionEntry, listed, withoutChildren } from "./sessionList";

/// Home-list copy: keys of the pane's string table.
export const HOME_LABELS = {
  readyForReview: "home.readyForReview",
  /// `{time}` is a compact age: "now", "5m", "3h", "6d", "2mo" or "1y".
  ago: "home.ago",
} as const satisfies Record<string, StringKey>;

/// Each list shows at most this many rows, newest first.
export const HOME_ROWS = 3;

/// What a new chat's home offers besides the composer (its welcome screen): every ask waiting on
/// the person (the inbox, HomeInbox.tsx: each open request of every other chat, newest first, none
/// capped, so no ask is left to find in its chat), and the open pull requests ready for review. A
/// session can sit in both. The current session, archived ones and side chats never show.
export function homeLists(
  sessions: AcpmuxSessionEntry[],
  currentId?: string,
  asks: readonly WatchedAsk[] = [],
  tabs: readonly AttentionTab[] = [],
): { waiting: NeedsYouItem[]; review: AcpmuxSessionEntry[] } {
  const others = withoutChildren(sessions.filter(listed)).filter((session) => session.sessionId !== currentId);
  const shown = new Set(others.map((session) => session.sessionId));
  return {
    waiting: needsYouItems({ sessions, asks, tabs }).filter((item) => item.kind === "tab" || shown.has(item.sessionId)),
    // Only the rows it shows are sorted, newest first: a stable sort of the filtered rows keeps the
    // order a sort of every chat would, and costs the few with a pull request, not every listed chat.
    review: others
      .filter((session) => session.pullRequest?.state === "open" && session.pullRequest.reviewReady)
      .sort((left, right) => (activityTime(right) ?? 0) - (activityTime(left) ?? 0))
      .slice(0, HOME_ROWS),
  };
}

/// A compact age for a row's right edge, from milliseconds since the epoch.
export function age(updatedAt: number | undefined, now = Date.now(), t: Translate = translate): string | undefined {
  const value = ageWithDate(
    updatedAt,
    now,
    (minutes, translate) => {
      if (minutes < 1) return translate("age.now");
      const steps: [number, StringKey][] = [
        [60 * 24 * 360, "age.years"],
        [60 * 24 * 30, "age.months"],
        [60 * 24, "age.days"],
        [60, "age.hours"],
        [1, "age.minutes"],
      ];
      const [size, unit] = steps.find(([size]) => minutes >= size)!;
      const count =
        unit === "age.years" ? Math.max(1, Math.round(minutes / (60 * 24 * 365))) : Math.floor(minutes / size);
      return translate(HOME_LABELS.ago, { time: translate(unit, { n: count }) });
    },
    t,
  );
  return value || undefined;
}
