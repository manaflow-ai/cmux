import React from "react";

import { HomeInbox, type HomeInboxActions, type HomeInboxLook } from "./HomeInbox";
import { useT } from "./i18n";

import { type WatchedAsk } from "./needsYou/model";
import type { AttentionTab } from "./needsYou/attentionTabs";
import { activityTime, type AcpmuxSessionEntry, chatPlace, projectLabel } from "./sessionList";
import { HOME_LABELS, homeLists, age } from "./homeListsModel";
import { pressToOpen } from "../../ui/pressToOpen";
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
  onPin,
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
  /// Pins an Auto-placed chat where it runs now (the host's `chat.placement {sessionId, placement:
  /// "pinned"}`): Auto no longer moves it. Without it no row offers the pin.
  onPin?: (sessionId: string) => void;
  look?: HomeInboxLook;
  /// False while the home's own chat shows an ask card, which takes the permission shortcuts.
  shortcuts?: boolean;
}) {
  const { waiting, review } = homeLists(sessions, currentId, asks, tabs);
  const t = useT();
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
              mark={<PullRequestIcon />}
              title={session.pullRequest!.title}
              detail={`#${session.pullRequest!.number}`}
              onSelect={onSelect}
              onPin={onPin}
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
  onPin,
}: {
  session: AcpmuxSessionEntry;
  mark: React.ReactNode;
  title?: string;
  detail?: string;
  onSelect: (sessionId: string) => void;
  onPin?: (sessionId: string) => void;
}) {
  const t = useT();
  const project = session.cwd ? projectLabel(session.cwd) : undefined;
  const when = age(activityTime(session), Date.now(), t);
  const place = rowPlace(session, t);
  return (
    <li className="acpmux-home-item">
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
        {place && (
          <span
            className="acpmux-home-meta acpmux-home-place"
            data-placement={session.placement}
            title={place.title ?? place.label}
          >
            {session.placement === "pinned" && <PinIcon />}
            {place.label}
          </span>
        )}
        {when && <span className="acpmux-home-meta">{when}</span>}
        <ChevronIcon />
      </button>
      {/* Its own button beside the row's: a pin is not an open (design/auto-chat-placement.md, Pinning). */}
      {onPin && session.placement === "auto" && place && (
        <button
          type="button"
          className="acpmux-home-pin"
          aria-label={t("home.placementPin", { place: place.name })}
          title={t("home.placementPin", { place: place.name })}
          onClick={() => onPin(session.sessionId)}
        >
          <PinIcon />
        </button>
      )}
    </li>
  );
}

/// The row's place (design/auto-chat-placement.md, Pinning): "Auto · <machine>", "Auto · Cloud" or
/// "Auto · This Mac" while Auto placed the chat; the plain place once pinned (a pin glyph beside it)
/// or picked by the person, which a chat on this Mac with no placement leaves out, as before.
function rowPlace(
  session: AcpmuxSessionEntry,
  t: ReturnType<typeof useT>,
): { label: string; name: string; title?: string } | undefined {
  const where = chatPlace(session);
  const name =
    where.kind === "peer" ? where.machine : where.kind === "cloud" ? t("composer.cloud") : t("composer.thisMac");
  if (session.placement === "auto") return { label: t("home.placementAuto", { place: name }), name };
  if (session.placement === "pinned") return { label: name, name, title: t("home.placementPinned", { place: name }) };
  return where.kind === "local" ? undefined : { label: name, name };
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
const PinIcon = () => (
  <Icon>
    <path d="M9.75 2.75 13.25 6.25M10.75 3.75 7.5 7 4.75 7.25 8.75 11.25 9 8.5 12.25 5.25M6.75 9.25 3 13" />
  </Icon>
);
const ChevronIcon = () => (
  <Icon>
    <path d="m6.25 4.25 3.5 3.75-3.5 3.75" />
  </Icon>
);
