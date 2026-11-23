import React, { memo } from "react";
import { useStableCallback } from "./stableCallback";

import { HomeInbox, type HomeInboxActions, type HomeInboxLook, HomeAge } from "./HomeInbox";
import { useT } from "./i18n";

import { type WatchedAsk } from "./needsYou/model";
import type { AttentionTab } from "./needsYou/attentionTabs";
import { activityTime, type AcpmuxSessionEntry, projectLabel } from "./sessionList";
import { HOME_LABELS, homeLists } from "./homeListsModel";
import { pressToOpen } from "../../ui/pressToOpen";
import { WithFacts } from "./chips/FactsHoverCard";
/// The lists under a new chat's composer. Each row opens its session. Renders
/// nothing when neither list has a row, so the home is the hero and composer alone.
export function HomeLists({
  sessions,
  currentId,
  asks,
  tabs,
  onSelect,
  onOpen,
  onAnswer,
  look,
  shortcuts = true,
}: {
  sessions: AcpmuxSessionEntry[];
  currentId?: string;
  /// Every chat's open requests (snapshot `asks`), for the inbox.
  asks?: readonly WatchedAsk[];
  /// Marked tabs have no session id; callers route them through chat.attention.open.
  tabs?: readonly AttentionTab[];
  onSelect: (sessionId: string) => void;
  onOpen?: HomeInboxActions["open"];
  /// Answers another chat's ask in place; rejects when it did not go through.
  onAnswer: HomeInboxActions["answer"];
  look?: HomeInboxLook;
  /// False while the home's own chat shows an ask card, which takes the permission shortcuts.
  shortcuts?: boolean;
}) {
  const { waiting, review } = homeLists(sessions, currentId, asks, tabs);
  const t = useT();
  // homeListsShown (homeListsModel.ts) answers the same question for the pane's `data-home-lists`.
  // One select for every row, calling the latest `onSelect`: a parent's new closure draws no row.
  const select = useStableCallback((sessionId: string) => onSelect(sessionId));
  if (waiting.length === 0 && review.length === 0) return null;
  return (
    <div className="acpmux-home">
      <HomeInbox
        items={waiting}
        sessions={sessions}
        look={look}
        shortcuts={shortcuts}
        actions={{
          answer: onAnswer,
          open: (item) => {
            if (onOpen) {
              onOpen(item);
            } else {
              onSelect(item.sessionId);
            }
          },
        }}
      />
      {review.length > 0 && (
        <HomeList label={t(HOME_LABELS.readyForReview)}>
          {review.map((session) => (
            <HomeRow
              key={session.sessionId}
              session={session}
              mark={PULL_REQUEST_MARK}
              title={session.pullRequest!.title}
              detail={`#${session.pullRequest!.number}`}
              onSelect={select}
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

/// One chat. Its own component, drawn again only when its session or its words change.
const HomeRow = memo(function HomeRow({
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
  const project = session.cwd ? projectLabel(session.cwd) : undefined;
  const at = activityTime(session);
  return (
    <li>
      <button type="button" className="acpmux-home-row" {...pressToOpen(() => onSelect(session.sessionId))}>
        {mark}
        <span className="acpmux-home-title">{title ?? session.displayTitle}</span>
        {detail && <span className="acpmux-home-detail">{detail}</span>}
        {project && (
          <WithFacts facts={[{ value: session.cwd ?? "", code: true }]}>
            {(facts) => (
              <span {...facts} className="acpmux-home-meta acpmux-home-project">
                {project}
              </span>
            )}
          </WithFacts>
        )}
        {at !== undefined && <HomeAge at={at} />}
        <ChevronIcon />
      </button>
    </li>
  );
});

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
/// The review list's mark, one element for every row and draw.
const PULL_REQUEST_MARK = <PullRequestIcon />;
