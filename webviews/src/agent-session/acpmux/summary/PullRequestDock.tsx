// A quiet count opens Session Info Changes. Its disclosure keeps PR links, hover cards and
// persistent dismissal reachable. The shared Changes selector includes ended and dismissed PRs:
// dismissal hides a shortcut, never a change the session made. Gallery variants retain full bars.
import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { Close } from "../conversation/icons";
import { pullRequestStateSince, useHeaderState, type HeaderPullRequest } from "../header/headerState";
import { transcriptPullRequestKey, transcriptPullRequests, type SummaryPullRequest } from "./transcriptPullRequests";
import { headerStatus, visibleChanges } from "../inspector/ChangesSection";
import { GitHubMark } from "../conversation/icons";
import { LinkHoverCard } from "../chips/LinkHoverCard";
import { useSiteInfo } from "../chips/linkStore";
import { useHoverCard } from "../chips/useHoverCard";

import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";

const SHOWN = 2;
export type PullRequestDockMode = "compact" | "none" | "collapsed" | "full";
const BADGES: Record<string, StringKey> = {
  open: "header.prBadge.open",
  draft: "header.prBadge.draft",
};

const storageKey = (sessionId: string) => `acpmux.prDock.dismissed.${sessionId}`;

/// Gallery-only variants set this document attribute. The real pane has no attribute and therefore
/// uses the quiet count line by default.
function configuredMode(): PullRequestDockMode {
  const value = typeof document === "undefined" ? undefined : document.documentElement.dataset.prDock;
  return value === "none" || value === "collapsed" || value === "full" ? value : "compact";
}

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
export function PullRequestDock({
  rows,
  sessionId,
  onOpenChanges,
  repository,
}: {
  rows: readonly AcpmuxRow[];
  sessionId?: string;
  onOpenChanges?: () => void;
  repository?: string;
}) {
  const t = useT();
  const { pullRequest: live } = useHeaderState();
  // Same options and membership selector as Session Info. Retain the parse cache across
  // streaming chunks with unchanged PR findings; a new verified mention still updates the count.
  const parsed = useRef<{ key: string | symbol; repository?: string; prs: SummaryPullRequest[] }>(undefined);
  const key = transcriptPullRequestKey(rows, true);
  if (parsed.current?.key !== key || parsed.current?.repository !== repository) {
    parsed.current = { key, repository, prs: transcriptPullRequests(rows, { folder: repository, replies: true }) };
  }
  const all = parsed.current.prs;
  const changes = visibleChanges(all, headerStatus(live));
  const [dismissed, setDismissed] = useState(() => readDismissed(sessionId));
  const [expanded, setExpanded] = useState(false);
  const list = useRef<HTMLDivElement>(null);
  const count = useRef<HTMLButtonElement>(null);
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  const trigger = usePopoverTrigger(expanded, setExpanded);
  const disclosure = useRef<HTMLButtonElement>(null);
  const listId = useId();
  // The place of the bar just dismissed: focus moves to the bar now there, or the composer.
  const [refocus, setRefocus] = useState<number>();
  useEffect(() => {
    if (refocus === undefined) return;
    setRefocus(undefined);
    const buttons = list.current?.querySelectorAll<HTMLElement>(".acpmux-pr-dock__dismiss");
    const next = buttons?.[Math.min(refocus, buttons.length - 1)];
    (
      next ??
      disclosure.current ??
      count.current ??
      document.querySelector<HTMLElement>(".acpmux-composer [contenteditable], .acpmux-composer textarea")
    )?.focus();
  }, [refocus]);
  const mode = configuredMode();
  const compact = mode === "compact" && !!onOpenChanges;
  const prs = (compact ? changes : all.filter((pr) => pr.opened && !ended(pr, live)))
    .filter((pr) => !dismissed.includes(pr.url))
    .reverse();
  if ((compact ? changes.length : prs.length) === 0 || mode === "none") return null;
  const displayMode = mode === "compact" && !compact ? "full" : mode;
  const visible = compact || displayMode === "collapsed" || expanded ? prs : prs.slice(0, SHOWN);
  const dismiss = (url: string, index: number) => {
    const next = [...dismissed, url];
    setDismissed(next);
    writeDismissed(sessionId, next);
    setRefocus(index);
    if (compact && prs.length === 1) setExpanded(false);
  };
  const bars = (
    <div
      ref={list}
      tabIndex={compact ? -1 : undefined}
      id={listId}
      className="acpmux-pr-dock__list"
      hidden={visible.length === 0}
    >
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
    </div>
  );
  return (
    <section className="acpmux-pr-dock" data-mode={displayMode} aria-label={t("prDock.label")}>
      {compact && (
        <div className="acpmux-pr-dock__compact">
          <button
            ref={count}
            type="button"
            className="acpmux-pr-dock__count"
            aria-label={t(changes.length === 1 ? "prDock.countOne" : "prDock.count", { count: String(changes.length) })}
            onClick={onOpenChanges}
          >
            <Icon name="git.pullrequest" size={13} />
            <span>
              {t(changes.length === 1 ? "prDock.countOne" : "prDock.count", { count: String(changes.length) })}
            </span>
          </button>
          {prs.length > 0 && (
            <button
              ref={(element) => {
                disclosure.current = element;
                setAnchor(element);
              }}
              type="button"
              className="acpmux-pr-dock__count acpmux-pr-dock__disclosure"
              aria-label={t("prDock.label")}
              aria-haspopup="dialog"
              aria-expanded={expanded}
              aria-controls={listId}
              {...trigger}
            >
              <Icon name={expanded ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
            </button>
          )}
        </div>
      )}
      {compact ? (
        <Popover
          open={expanded && prs.length > 0}
          onOpenChange={setExpanded}
          anchor={anchor}
          label={t("prDock.label")}
          className="acpmux-pr-dock__popover"
          side="top"
          initialFocus={list}
          finalFocus={prs.length > 0 ? disclosure : count}
        >
          {bars}
        </Popover>
      ) : (
        bars
      )}
      {displayMode === "full" && prs.length > SHOWN && (
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
