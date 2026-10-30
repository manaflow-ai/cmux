// The chat's pull requests in the bottom stack (bottomStack.css): one line, "N PRs", whose
// disclosure opens the chips under it at the card's full width (Leo, 2026-10-30: "you guys fucking
// removed the # prs thing entirely instead of just simply fucking doing it"). It is the collapsed
// count line the dock had before cmux#26082 moved the pills into each message's action row; those
// pills stay. The row's columns are the running tray header's (subagents.css): the mark on the
// stack's lead, the count on its text column, the chevron on its trailing column, so the two read
// as one list. The list opens on the click, with no fade-in (Leo, 2026-10-24: "You click, you get a
// response, period"), and its chips keep the reply links' hover card.
import { useId, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { useHeaderState } from "../header/headerState";
import { GitHubMark } from "../conversation/icons";
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

/// Mount keyed by the chat: whether the list is open belongs to one chat.
export function PullRequestStack({ prs }: { prs: readonly SummaryPullRequest[] }) {
  const t = useT();
  const { pullRequest: live } = useHeaderState();
  const [open, setOpen] = useState(false);
  const listId = useId();
  if (prs.length === 0) return null;
  const count = t(prs.length === 1 ? "prDock.countOne" : "prDock.count", { count: String(prs.length) });
  const shown = (pr: SummaryPullRequest) => {
    const followed = live?.url === pr.url;
    return {
      state: followed ? live.state : pr.state,
      title: (followed ? live.title : undefined) || pr.title || "",
    };
  };
  return (
    <section className="acpmux-pr-stack" aria-label={t("prDock.label")} data-open={open || undefined}>
      <div className="acpmux-pr-stack__head">
        <button
          type="button"
          className="acpmux-summary-row acpmux-summary-link acpmux-pr-stack__row"
          aria-expanded={open}
          aria-controls={open ? listId : undefined}
          onClick={() => setOpen(!open)}
        >
          <span className="acpmux-pr-stack__mark" aria-hidden="true">
            <Icon name="git.pullrequest" size={14} />
          </span>
          <span className="acpmux-summary-text acpmux-pr-stack__count">{count}</span>
          <span className="acpmux-pr-stack__status" aria-hidden="true">
            <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={ROW_ICON} row />
          </span>
        </button>
        {/* The compact strip (a gallery comparison): the links on the count's own line. */}
        {stackLook() === "strip" && (
          <span className="acpmux-pr-stack__inline">
            {prs.map((pr) => (
              <PullRequestChip key={pr.url} pr={pr} {...shown(pr)} className="acpmux-pr-stack__inline-link">
                <span className="acpmux-pr-stack__number">#{pr.number}</span>
                <span className="acpmux-pr-stack__repo">{pr.repo.split("/").pop()}</span>
              </PullRequestChip>
            ))}
          </span>
        )}
      </div>
      {open && (
        <ul id={listId} className="acpmux-pr-stack__list">
          {prs.map((pr) => {
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
