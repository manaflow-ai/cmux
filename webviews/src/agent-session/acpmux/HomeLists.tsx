import React from "react";
import { type StringKey, type Translate, translate, useT } from "./i18n";
import { type AcpmuxSessionEntry, listed, projectLabel, sessionMark } from "./sessionList";

/// Home-list copy: keys of the pane's string table.
export const HOME_LABELS = {
  needsInput: "home.needsInput",
  readyForReview: "home.readyForReview",
  /// `{time}` is a compact age: "now", "5m", "3h", "6d", "2mo" or "1y".
  ago: "home.ago",
} as const satisfies Record<string, StringKey>;

/// Each list shows at most this many rows, newest first.
export const HOME_ROWS = 3;

/// What a new chat's home offers besides the composer (its welcome screen):
/// the other sessions waiting on the user, and the open pull requests ready for
/// review. A session can sit in both lists. The current session, archived ones and side chats never show.
export function homeLists(
  sessions: AcpmuxSessionEntry[],
  currentId?: string,
): { input: AcpmuxSessionEntry[]; review: AcpmuxSessionEntry[] } {
  const others = sessions
    .filter((session) => session.sessionId !== currentId && listed(session))
    .sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0));
  return {
    input: others.filter((session) => sessionMark(session, false) === "input").slice(0, HOME_ROWS),
    review: others
      .filter((session) => session.pullRequest?.state === "open" && session.pullRequest.reviewReady)
      .slice(0, HOME_ROWS),
  };
}

/// A compact age for a row's right edge, from milliseconds since the epoch.
export function age(updatedAt: number | undefined, now = Date.now(), t: Translate = translate): string | undefined {
  if (updatedAt === undefined) return undefined;
  const minutes = Math.floor(Math.max(0, now - updatedAt) / 60_000);
  if (minutes < 1) return t("age.now");
  const steps: [number, StringKey][] = [
    [60 * 24 * 360, "age.years"],
    [60 * 24 * 30, "age.months"],
    [60 * 24, "age.days"],
    [60, "age.hours"],
    [1, "age.minutes"],
  ];
  const [size, unit] = steps.find(([size]) => minutes >= size)!;
  // A year starts at 12 months of 30 days, so no age reads "12mo".
  const count = unit === "age.years" ? Math.max(1, Math.round(minutes / (60 * 24 * 365))) : Math.floor(minutes / size);
  return t(HOME_LABELS.ago, { time: t(unit, { n: count }) });
}

/// The lists under a new chat's composer. Each row opens its session. Renders
/// nothing when neither list has a row, so the home is the hero and composer alone.
export function HomeLists({
  sessions,
  currentId,
  onSelect,
}: {
  sessions: AcpmuxSessionEntry[];
  currentId?: string;
  onSelect: (sessionId: string) => void;
}) {
  const t = useT();
  const { input, review } = homeLists(sessions, currentId);
  if (input.length === 0 && review.length === 0) return null;
  return (
    <div className="acpmux-home">
      {input.length > 0 && (
        <HomeList label={t(HOME_LABELS.needsInput)}>
          {input.map((session) => (
            <HomeRow
              key={session.sessionId}
              session={session}
              mark={<span className="acpmux-home-dot" aria-hidden="true" />}
              detail={session.preview}
              onSelect={onSelect}
            />
          ))}
        </HomeList>
      )}
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
  const when = age(session.updatedAt, Date.now(), t);
  return (
    <li>
      <button type="button" className="acpmux-home-row" onClick={() => onSelect(session.sessionId)}>
        {mark}
        <span className="acpmux-home-title">{title ?? session.displayTitle}</span>
        {detail && <span className="acpmux-home-detail">{detail}</span>}
        {project && <span className="acpmux-home-meta">{project}</span>}
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
