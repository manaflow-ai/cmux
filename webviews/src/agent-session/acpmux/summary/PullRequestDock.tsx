// PR shortcuts belong to the message's existing line. Overflow is a portal: opening it never
// changes the transcript's measured height. Parsing keeps the producer's PR revision cache.
import { createContext, useContext, useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { useHeaderState } from "../header/headerState";
import { transcriptPullRequestKey, transcriptPullRequests, type SummaryPullRequest } from "./transcriptPullRequests";
import { headerStatus, visibleChanges } from "../inspector/ChangesSection";
import { GitHubMark } from "../conversation/icons";
import { LinkHoverCard } from "../chips/LinkHoverCard";
import { useSiteInfo } from "../chips/linkStore";
import { useHoverCard } from "../chips/useHoverCard";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { PullRequestHostVisibility } from "./pullRequestPlacement";

/// Existing comparison treatments are opt-in gallery document attributes only.
export function legacyPullRequestDockMode() {
  const mode = typeof document === "undefined" ? undefined : document.documentElement.dataset.prDock;
  return mode === "compact" || mode === "none" || mode === "collapsed" || mode === "full";
}

export const RowPullRequests = createContext<readonly SummaryPullRequest[] | undefined>(undefined);

export function useTranscriptPullRequests(rows: readonly AcpmuxRow[], repository?: string) {
  const { pullRequest: live } = useHeaderState();
  // The dock counts the same session-owned Changes as Session Info. Read-only reply mentions are
  // Sources, so the cache fingerprints command findings only and skips per-token prose work.
  const parsed = useRef<{ key: string | symbol; repository?: string; prs: SummaryPullRequest[] }>(undefined);
  // Use the producer revision even though the dock parses commands only: the revision is O(1)
  // for live snapshots and advances only when a tool finding changes.
  const key = transcriptPullRequestKey(rows, false);
  if (parsed.current?.key !== key || parsed.current?.repository !== repository) {
    parsed.current = {
      key,
      repository,
      prs: transcriptPullRequests(rows, { folder: repository, replies: false }),
    };
  }
  const all = parsed.current.prs;
  const legacy = legacyPullRequestDockMode();
  return useMemo(() => (legacy ? [] : visibleChanges(all, headerStatus(live)).reverse()), [all, live, legacy]);
}

export function PullRequestDock() {
  const prs = useContext(RowPullRequests);
  if (!prs?.length) return null;
  return <PullRequestPills prs={prs} />;
}

function PullRequestPills({ prs }: { prs: readonly SummaryPullRequest[] }) {
  const t = useT();
  const reportHost = useContext(PullRequestHostVisibility);
  useLayoutEffect(() => {
    reportHost?.(true);
    return () => reportHost?.(false);
  }, [reportHost]);
  const { pullRequest: live } = useHeaderState();
  const [open, setOpen] = useState(false);
  const [count, setCount] = useState(Math.min(2, prs.length));
  const row = useRef<HTMLSpanElement>(null);
  const measure = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const press = usePopoverTrigger(open, setOpen);
  const mode = typeof document === "undefined" ? undefined : document.documentElement.dataset.prDock;
  const limit = mode === "one" ? 1 : 2;
  useLayoutEffect(() => {
    const node = row.current;
    const sizing = measure.current;
    if (!node || !sizing) return;
    const fit = () => {
      const widths = [...sizing.children].map((child) => child.getBoundingClientRect().width);
      const more = widths[2] ?? 0;
      const gap = parseFloat(getComputedStyle(node).columnGap) || 0;
      const two = (widths[0] ?? 0) + (widths[1] ?? 0) + gap + (prs.length > 2 ? more + gap : 0);
      setCount(prs.length > 1 && limit > 1 && two <= node.clientWidth ? 2 : 1);
    };
    fit();
    const observer = new ResizeObserver(fit);
    observer.observe(node);
    observer.observe(sizing);
    return () => observer.disconnect();
  }, [prs, limit]);
  const visible = Math.min(count, prs.length);
  const link = (pr: SummaryPullRequest) => (
    <PullRequestBar
      key={pr.url}
      pr={pr}
      state={live?.url === pr.url ? live.state : pr.state}
      title={live?.url === pr.url ? live.title || pr.title || "" : pr.title || ""}
    >
      <span className="acpmux-pr-dock__number">#{pr.number}</span>
      <span className="acpmux-pr-dock__repo">{pr.repo.split("/").pop()}</span>
    </PullRequestBar>
  );
  return (
    <span ref={row} className="acpmux-pr-dock" aria-label={t("prDock.label")}>
      <span ref={measure} className="acpmux-pr-dock__measure" aria-hidden="true">
        {prs.slice(0, 2).map((pr) => (
          <span key={pr.url}>
            #{pr.number} {pr.repo.split("/").pop()}
          </span>
        ))}
        {prs.length === 1 && <span />}
        <span>+{prs.length - 1}</span>
      </span>
      {prs.slice(0, visible).map(link)}
      {prs.length > visible && (
        <button
          ref={trigger}
          type="button"
          className="acpmux-pr-dock__more"
          aria-label={t("prDock.more", { count: prs.length - visible })}
          aria-haspopup="dialog"
          aria-expanded={open}
          {...press}
        >
          +{prs.length - visible}
        </button>
      )}
      <Popover
        open={open && prs.length > visible}
        onOpenChange={setOpen}
        anchor={trigger.current}
        finalFocus={trigger}
        label={t("prDock.label")}
        side="top"
        className="acpmux-pr-dock__popover"
      >
        {prs.slice(visible).map(link)}
      </Popover>
    </span>
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
