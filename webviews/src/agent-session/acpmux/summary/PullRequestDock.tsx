// The chat's pull requests above the composer (cx-ncc.81, Claude desktop's PR bars): each one a
// `gh pr create` in the chat opened (sessionSummary.ts), newest first, with its number, repository,
// title and state, each a chip as wide as its text, its title cut off only when the composer's
// column is full, with its dismiss button inside. The chat folder's pull request, which the header
// chip follows live, shows its live state and title. A merged or closed pull request keeps no bar:
// it lives in the right panel's Changes card instead. The newest two show and the rest wait behind
// Show more; a dismissed bar stays hidden for this chat (the page's storage, so a reload keeps it
// hidden). Hovering a bar, or focusing it, opens the shared link card (chips/LinkHoverCard.tsx) with
// the pull request's full title, state, author and checks.
import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { Close } from "../conversation/icons";
import { pullRequestStateSince, useHeaderState, type HeaderPullRequest } from "../header/headerState";
import { sessionPullRequests, type SummaryPullRequest } from "./sessionSummary";
import { GitHubMark } from "../conversation/icons";
import { LinkHoverCard } from "../chips/LinkHoverCard";
import { useSiteInfo } from "../chips/linkStore";
import { useHoverCard } from "../chips/useHoverCard";

const SHOWN = 2;
const BADGES: Record<string, StringKey> = {
  open: "header.prBadge.open",
  draft: "header.prBadge.draft",
};

const storageKey = (sessionId: string) => `acpmux.prDock.dismissed.${sessionId}`;

/// The pull request URLs dismissed in this chat; none when the page has no storage.
function readDismissed(sessionId: string | undefined): string[] {
  if (!sessionId) return [];
  try {
    const value: unknown = JSON.parse(localStorage.getItem(storageKey(sessionId)) ?? "[]");
    return Array.isArray(value) ? value.filter((url): url is string => typeof url === "string") : [];
  } catch {
    return [];
  }
}

function writeDismissed(sessionId: string | undefined, urls: readonly string[]): void {
  if (!sessionId) return;
  try {
    localStorage.setItem(storageKey(sessionId), JSON.stringify(urls));
  } catch {
    // Without storage the bar stays hidden until the page reloads.
  }
}

/// A bar's state and title: the live ones when the header follows this pull request. Without
/// them, "open" is only what the chat last saw, so the bar names no state rather than a stale one.
function shown(
  pr: SummaryPullRequest,
  live: HeaderPullRequest | undefined,
): { state: string; title: string; labeled: boolean } {
  if (live?.url === pr.url) return { state: live.state, title: live.title || (pr.title ?? ""), labeled: true };
  return { state: pr.state, title: pr.title ?? "", labeled: false };
}

/// Whether `pr` is merged or closed, so it keeps no bar. A merge the chat ran is final; a close it
/// ran holds until the header reads the pull request again after it (a reopen), as the Changes card
/// decides (inspector/ChangesSection.tsx rowState). An open one defers to the header's live read.
function ended(pr: SummaryPullRequest, live: HeaderPullRequest | undefined): boolean {
  if (pr.state === "merged") return true;
  const state = live?.url === pr.url ? live.state : undefined;
  if (pr.state !== "closed") return state === "merged" || state === "closed";
  const since = state === undefined ? undefined : pullRequestStateSince(pr.url);
  const reopened = since !== undefined && pr.closedAt !== undefined && since > pr.closedAt;
  return !(reopened && (state === "open" || state === "draft"));
}

/// Mount keyed by the chat: dismissals and Show more belong to one chat.
export function PullRequestDock({ rows, sessionId }: { rows: readonly AcpmuxRow[]; sessionId?: string }) {
  const t = useT();
  const { pullRequest: live } = useHeaderState();
  // Every streamed chunk is a new rows array: parse again only when a tool call changed.
  const parsed = useRef<{ key: string; prs: SummaryPullRequest[] }>(undefined);
  const key = rows.flatMap((row) => (row.kind === "activity" ? [`${row.id}:${row.version}`] : [])).join(",");
  if (parsed.current?.key !== key) parsed.current = { key, prs: sessionPullRequests(rows) };
  const all = parsed.current.prs;
  const [dismissed, setDismissed] = useState(() => readDismissed(sessionId));
  const [expanded, setExpanded] = useState(false);
  const dock = useRef<HTMLElement>(null);
  // The place of the bar just dismissed: focus moves to the bar now there, or the composer.
  const [refocus, setRefocus] = useState<number>();
  useEffect(() => {
    if (refocus === undefined) return;
    setRefocus(undefined);
    const buttons = dock.current?.querySelectorAll<HTMLElement>(".acpmux-pr-dock__dismiss");
    const next = buttons?.[Math.min(refocus, buttons.length - 1)];
    (
      next ?? document.querySelector<HTMLElement>(".acpmux-composer [contenteditable], .acpmux-composer textarea")
    )?.focus();
  }, [refocus]);
  const prs = all.filter((pr) => !dismissed.includes(pr.url) && !ended(pr, live)).reverse();
  if (prs.length === 0) return null;
  const visible = expanded ? prs : prs.slice(0, SHOWN);
  const dismiss = (url: string, index: number) => {
    const next = [...dismissed, url];
    setDismissed(next);
    writeDismissed(sessionId, next);
    setRefocus(index);
  };
  return (
    <section ref={dock} className="acpmux-pr-dock" aria-label={t("prDock.label")}>
      {visible.map((pr, index) => {
        const { state, title, labeled } = shown(pr, live);
        const badge = BADGES[state];
        return (
          <div key={pr.url} className="acpmux-pr-dock__chip">
            <PullRequestBar pr={pr} state={state} title={title}>
              <Icon name="git.pullrequest" size={13} />
              <span className="acpmux-pr-dock__number">#{pr.number}</span>
              <span className="acpmux-pr-dock__repo">{pr.repo.split("/").pop()}</span>
              {title && <span className="acpmux-pr-dock__title">{title}</span>}
              {labeled && <span className="acpmux-pr-dock__state">{badge ? t(badge) : state}</span>}
            </PullRequestBar>
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact acpmux-pr-dock__dismiss"
              aria-label={t("prDock.dismiss", { number: pr.number })}
              onClick={() => dismiss(pr.url, index)}
            >
              <Close size={12} />
            </button>
          </div>
        );
      })}
      {prs.length > SHOWN && (
        <button
          type="button"
          className="acpmux-pr-dock__more"
          aria-expanded={expanded}
          onClick={() => setExpanded(!expanded)}
        >
          {expanded ? t("prDock.less") : t("prDock.more", { count: prs.length - SHOWN })}
        </button>
      )}
    </section>
  );
}

/// One bar's link and its hover card, the same card as a pull request link in a reply.
function PullRequestBar({
  pr,
  state,
  title,
  children,
}: {
  pr: SummaryPullRequest;
  state: string;
  title: string;
  children: ReactNode;
}) {
  const hover = useHoverCard();
  const site = useSiteInfo(pr.url);
  const [bar, setBar] = useState<HTMLAnchorElement | null>(null);
  const card = useId();
  return (
    <>
      <a
        ref={setBar}
        className="acpmux-pr-dock__bar"
        href={pr.url}
        data-state={state}
        aria-describedby={hover.open ? card : undefined}
        {...hover.trigger}
      >
        {children}
      </a>
      <LinkHoverCard
        id={card}
        href={pr.url}
        anchor={bar}
        hover={hover}
        mark={<GitHubMark size={13} className="cv-chip__icon cv-chip__icon--gh" />}
        siteTitle={site?.title}
        pullRequest={{ repo: pr.repo, number: pr.number, title, state }}
        side="top"
      />
    </>
  );
}
