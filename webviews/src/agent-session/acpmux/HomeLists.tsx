import React from "react";
import { pressToOpen } from "../../ui/pressToOpen";
import { HomeInbox, type HomeInboxActions, type HomeInboxLook } from "./HomeInbox";
import { type StringKey, type Translate, translate, useT } from "./i18n";
import { ageWithDate } from "./timeLabels";
import { needsYouItems, type NeedsYouItem, type WatchedAsk } from "./needsYou/model";
import { activityTime, type AcpmuxSessionEntry, listed, projectLabel, withoutChildren } from "./sessionList";

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
): { waiting: NeedsYouItem[]; review: AcpmuxSessionEntry[] } {
  const others = withoutChildren(sessions.filter(listed))
    .filter((session) => session.sessionId !== currentId)
    .sort((left, right) => (activityTime(right) ?? 0) - (activityTime(left) ?? 0));
  const shown = new Set(others.map((session) => session.sessionId));
  return {
    waiting: needsYouItems({ sessions, asks }).filter((item) => shown.has(item.sessionId)),
    review: others
      .filter((session) => session.pullRequest?.state === "open" && session.pullRequest.reviewReady)
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

/// The lists under a new chat's composer. Each row opens its session. Renders
/// nothing when neither list has a row, so the home is the hero and composer alone.
export function HomeLists({
  sessions,
  currentId,
  asks,
  onSelect,
  onAnswer,
  look,
  shortcuts = true,
}: {
  sessions: AcpmuxSessionEntry[];
  currentId?: string;
  /// Every chat's open requests (snapshot `asks`), for the inbox.
  asks?: readonly WatchedAsk[];
  onSelect: (sessionId: string) => void;
  /// Answers another chat's ask in place; rejects when it did not go through.
  onAnswer: HomeInboxActions["answer"];
  look?: HomeInboxLook;
  /// False while the home's own chat shows an ask card, which takes the permission shortcuts.
  shortcuts?: boolean;
}) {
  const { waiting, review } = homeLists(sessions, currentId, asks);
  const t = useT();
  if (waiting.length === 0 && review.length === 0) return null;
  return (
    <div className="acpmux-home">
      <HomeInbox
        items={waiting}
        sessions={sessions}
        look={look}
        shortcuts={shortcuts}
        actions={{ answer: onAnswer, open: (item) => onSelect(item.sessionId) }}
      />
      {review.length > 0 && (
        <HomeList label={t(HOME_LABELS.readyForReview)}>
          {review.map((session) => (
            <HomeRow
              key={session.sessionId}
              session={session}
              mark={<PullRequestIcon />}
              title={session.pullRequest!.title}
              detail={`#${session.pullRequest!.number}`}
              onSelect={onSelect}
            />
          ))}
        </HomeList>
      )}
    </div>
  );
}

function HomeList({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <section className="acpmux-home-list" aria-label={label}>
      <h3 className="acpmux-home-label">{label}</h3>
      <ul>{children}</ul>
    </section>
  );
}

function HomeRow({
  session,
  mark,
  title,
  detail,
  onSelect,
}: {
  session: AcpmuxSessionEntry;
  mark: React.ReactNode;
  title?: string;
  detail?: string;
  onSelect: (sessionId: string) => void;
}) {
  const t = useT();
  const project = session.cwd ? projectLabel(session.cwd) : undefined;
  const when = age(activityTime(session), Date.now(), t);
  return (
    <li>
      <button type="button" className="acpmux-home-row" {...pressToOpen(() => onSelect(session.sessionId))}>
        {mark}
        <span className="acpmux-home-title" title={title ?? session.displayTitle}>
          {title ?? session.displayTitle}
        </span>
        {detail && (
          <span className="acpmux-home-detail" title={detail}>
            {detail}
          </span>
        )}
        {project && (
          <span className="acpmux-home-meta acpmux-home-project" title={session.cwd}>
            {project}
          </span>
        )}
        {when && <span className="acpmux-home-meta">{when}</span>}
        <ChevronIcon />
      </button>
    </li>
  );
}

function Icon({ children }: { children: React.ReactNode }) {
  return (
    <svg
      className="acpmux-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}
const PullRequestIcon = () => (
  <Icon>
    <circle cx="4.5" cy="3.75" r="1.5" />
    <circle cx="4.5" cy="12.25" r="1.5" />
    <circle cx="11.5" cy="12.25" r="1.5" />
    <path d="M4.5 5.25v5.5M11.5 10.75V6.25c0-.83-.67-1.5-1.5-1.5H7.75M9.25 3.25l-1.5 1.5 1.5 1.5" />
  </Icon>
);
const ChevronIcon = () => (
  <Icon>
    <path d="m6.25 4.25 3.5 3.75-3.5 3.75" />
  </Icon>
);
