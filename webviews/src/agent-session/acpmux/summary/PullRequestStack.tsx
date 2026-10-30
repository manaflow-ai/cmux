// The chat's pull requests in the bottom stack (bottomStack.css): one line, "N PRs", whose
// disclosure opens the chips under it at the card's full width (Leo, 2026-10-30: "you guys fucking
// removed the # prs thing entirely instead of just simply fucking doing it"). It is the collapsed
// count line the dock had before cmux#26082 moved the pills into each message's action row (#26441
// aligned it last); those pills stay. The row's columns are the running tray header's
// (subagents.css): the mark on the stack's lead, the count on its text column, the chevron on its
// trailing column, so the two read as one list. The list opens on the click, with no fade-in (Leo,
// 2026-10-24: "You click, you get a response, period"), and its chips keep the reply links' hover
// card and the dock's × dismissal.
import { useId, useRef, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { useHeaderState } from "../header/headerState";
import { Close, GitHubMark } from "../conversation/icons";
import { LinkHoverCard } from "../chips/LinkHoverCard";
import { useSiteInfo } from "../chips/linkStore";
import { useHoverCard } from "../chips/useHoverCard";
import { rowIconSize } from "../icons/iconSize";
import type { SummaryPullRequest } from "./transcriptPullRequests";

const ROW_ICON = rowIconSize(12);

/// The gallery's comparison looks set this document attribute (bottomStack.css); the live pane has
/// none and draws the selected look.
function stackLook(): string | undefined {
  return typeof document === "undefined" ? undefined : document.documentElement.dataset.bottomStack;
}

const storageKey = (sessionId: string) => `acpmux.prDock.dismissed.${sessionId}`;

/// The pull request URLs dismissed in this chat, the same list the dock kept before cmux#26082
/// (PullRequestDockLegacy.tsx), so a shortcut dismissed then stays dismissed.
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
    // Without storage the chip stays hidden until the page reloads.
  }
}

/// Mount keyed by the chat: whether the list is open, and what was dismissed, belong to one chat.
/// The count is Session Info's Changes (session-info.md, "Leo's PR dock decision"): it opens them
/// with `onOpenChanges`, and counts a dismissed or ended change too; the disclosure beside it opens
/// the chips, and a chip's × hides only that shortcut.
export function PullRequestStack({
  prs,
  sessionId,
  onOpenChanges,
}: {
  prs: readonly SummaryPullRequest[];
  sessionId?: string;
  onOpenChanges?: () => void;
}) {
  const t = useT();
  const { pullRequest: live } = useHeaderState();
  const [open, setOpen] = useState(false);
  const [dismissed, setDismissed] = useState(() => readDismissed(sessionId));
  const listId = useId();
  const disclosure = useRef<HTMLButtonElement>(null);
  const list = useRef<HTMLUListElement>(null);
  if (prs.length === 0) return null;
  const chips = prs.filter((pr) => !dismissed.includes(pr.url));
  const expanded = open && chips.length > 0;
  const count = t(prs.length === 1 ? "prDock.countOne" : "prDock.count", { count: String(prs.length) });
  const shown = (pr: SummaryPullRequest) => {
    const followed = live?.url === pr.url;
    return {
      state: followed ? live.state : pr.state,
      title: (followed ? live.title : undefined) || pr.title || "",
    };
  };
  const dismiss = (url: string, index: number) => {
    const next = [...dismissed, url];
    setDismissed(next);
    writeDismissed(sessionId, next);
    // Focus moves to the × now in that place, or back to the disclosure when none is left.
    requestAnimationFrame(() => {
      const buttons = list.current?.querySelectorAll<HTMLElement>(".acpmux-pr-stack__dismiss");
      (buttons?.[Math.min(index, buttons.length - 1)] ?? disclosure.current)?.focus();
    });
  };
  const toggle = () => setOpen(!expanded);
  return (
    <section className="acpmux-pr-stack" aria-label={t("prDock.label")} data-open={expanded || undefined}>
      <div className="acpmux-pr-stack__head">
        <button
          type="button"
          className="acpmux-summary-row acpmux-summary-link acpmux-pr-stack__row"
          onClick={onOpenChanges ?? toggle}
        >
          <span className="acpmux-pr-stack__mark" aria-hidden="true">
            <Icon name="git.pullrequest" size={14} />
          </span>
          <span className="acpmux-summary-text acpmux-pr-stack__count">{count}</span>
        </button>
        {/* The compact strip (a gallery comparison): the links on the count's own line. */}
        {stackLook() === "strip" && (
          <span className="acpmux-pr-stack__inline">
            {chips.map((pr) => (
              <PullRequestChip key={pr.url} pr={pr} {...shown(pr)} className="acpmux-pr-stack__inline-link">
                <span className="acpmux-pr-stack__number">#{pr.number}</span>
                <span className="acpmux-pr-stack__repo">{pr.repo.split("/").pop()}</span>
              </PullRequestChip>
            ))}
          </span>
        )}
        {chips.length > 0 && (
          <button
            ref={disclosure}
            type="button"
            className="acpmux-summary-link acpmux-pr-stack__disclosure"
            aria-label={t("prDock.label")}
            aria-expanded={expanded}
            aria-controls={expanded ? listId : undefined}
            onClick={toggle}
          >
            <Icon name={expanded ? "disclosure.expanded" : "disclosure.collapsed"} size={ROW_ICON} row />
          </button>
        )}
      </div>
      {expanded && (
        <ul ref={list} id={listId} className="acpmux-pr-stack__list">
          {chips.map((pr, index) => {
            const { state, title } = shown(pr);
            return (
              <li key={pr.url} className="acpmux-pr-stack__chip">
                <PullRequestChip
                  pr={pr}
                  state={state}
                  title={title}
                  className="acpmux-summary-row acpmux-summary-link acpmux-pr-stack__link"
                >
                  <span className="acpmux-pr-stack__mark" aria-hidden="true">
                    <Icon name="git.pullrequest" size={14} />
                  </span>
                  <span className="acpmux-pr-stack__label">
                    <span className="acpmux-pr-stack__number">#{pr.number}</span>
                    <span className="acpmux-pr-stack__repo">{pr.repo.split("/").pop()}</span>
                    {title && <span className="acpmux-pr-stack__title">{title}</span>}
                  </span>
                </PullRequestChip>
                <button
                  type="button"
                  className="cv-iconbtn cv-iconbtn--compact acpmux-pr-stack__dismiss"
                  aria-label={t("prDock.dismiss", { number: pr.number })}
                  onClick={() => dismiss(pr.url, index)}
                >
                  <Close size={12} />
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

/// One chip's link and its hover card, the same card as a pull request link in a reply.
function PullRequestChip({
  pr,
  state,
  title,
  className,
  children,
}: {
  pr: SummaryPullRequest;
  state: string;
  title: string;
  className: string;
  children: ReactNode;
}) {
  const hover = useHoverCard();
  const site = useSiteInfo(pr.url);
  const [chip, setChip] = useState<HTMLAnchorElement | null>(null);
  const card = useId();
  return (
    <>
      <a
        ref={setChip}
        className={className}
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
        anchor={chip}
        hover={hover}
        mark={<GitHubMark size={13} className="cv-chip__icon cv-chip__icon--gh" />}
        siteTitle={site?.title}
        pullRequest={{ repo: pr.repo, number: pr.number, title, state }}
        side="top"
      />
    </>
  );
}
