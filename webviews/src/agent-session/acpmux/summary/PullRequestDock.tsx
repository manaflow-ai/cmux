// PR shortcuts belong to the message's existing line. Each chip is its number, plus its title when a
// readable part of it fits (pullRequestChipPlan.ts), never a stub of a few letters. Overflow is a portal: opening it never
// changes the transcript's measured height. Parsing keeps the producer's PR revision cache.
import { createContext, useContext, useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { useHeaderState, type HeaderState } from "../header/headerState";
import { transcriptPullRequestKey, transcriptPullRequests, type SummaryPullRequest } from "./transcriptPullRequests";
import { headerStatus, visibleChanges } from "../inspector/ChangesSection";
import { GitHubMark } from "../conversation/icons";
import { LinkHoverCard } from "../chips/LinkHoverCard";
import { useSiteInfo } from "../chips/linkStore";
import { githubRefTitle } from "../chips/LinkChips";
import { useHoverCard } from "../chips/useHoverCard";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { PullRequestHostVisibility } from "./pullRequestPlacement";
import { planPullRequestChips, type PullRequestChipPlan } from "./pullRequestChipPlan";

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

/// The least title a chip draws, in characters: a shorter cut reads as a stub ("cm…"), so the chip
/// shows its number alone instead and its hover card gives the whole title.
export const MIN_TITLE_CHARS = 12;

/// The gallery's comparison treatments (document attribute `pr-dock`): `numbers` draws numbers
/// only, `one` at most one chip, `inline` keeps the row on the reply's last line (InlineTail.tsx).
export function pullRequestDockVariant(): string | undefined {
  return typeof document === "undefined" ? undefined : document.documentElement.dataset.prDock;
}

type LivePullRequest = HeaderState["pullRequest"];

/// A pull request's title as cmux knows it: the header's live one, the title the chat gave it, or
/// the one GitHub's page title carries.
function usePullRequestTitle(pr: SummaryPullRequest, live: LivePullRequest) {
  const site = useSiteInfo(pr.url);
  const own = live?.url === pr.url ? live.title || pr.title : pr.title;
  return (own || githubRefTitle(site?.title) || "").trim();
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
  const [plan, setPlan] = useState<PullRequestChipPlan>({ count: Math.min(2, prs.length), titled: false, short: [] });
  const row = useRef<HTMLSpanElement>(null);
  const measure = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const press = usePopoverTrigger(open, setOpen);
  const mode = pullRequestDockVariant();
  const limit = mode === "one" ? 1 : 2;
  const withTitles = mode !== "numbers";
  useLayoutEffect(() => {
    const node = row.current;
    const sizing = measure.current;
    if (!node || !sizing) return;
    const fit = () => {
      const width = (selector: string) =>
        [...sizing.querySelectorAll(selector)].map((child) => child.getBoundingClientRect().width);
      const next = planPullRequestChips({
        room: node.clientWidth,
        gap: parseFloat(getComputedStyle(node).columnGap) || 0,
        numbers: width("[data-measure=number]"),
        titles: width("[data-measure=title]"),
        more: width("[data-measure=more]"),
        minTitle: width("[data-measure=min]")[0] ?? 0,
        limit,
        total: prs.length,
        withTitles,
      });
      setPlan((previous) =>
        previous.count === next.count &&
        previous.titled === next.titled &&
        previous.short.length === next.short.length &&
        previous.short.every((short, index) => short === next.short[index])
          ? previous
          : next,
      );
    };
    fit();
    const observer = new ResizeObserver(fit);
    observer.observe(node);
    observer.observe(sizing);
    return () => observer.disconnect();
  }, [prs, limit, withTitles]);
  const visible = Math.min(plan.count, prs.length);
  const rest = prs.length - visible;
  return (
    <span ref={row} className="acpmux-pr-dock" aria-label={t("prDock.label")}>
      <span ref={measure} className="acpmux-pr-dock__measure" aria-hidden="true">
        {prs.slice(0, limit).map((pr) => (
          <MeasureChip key={pr.url} pr={pr} live={live} />
        ))}
        {prs.slice(0, limit).map((pr, index) => (
          <span key={pr.url} data-measure="more">
            +{prs.length - index - 1}
          </span>
        ))}
        <span data-measure="min" />
      </span>
      {prs.slice(0, visible).map((pr, index) => (
        <PullRequestChip key={pr.url} pr={pr} live={live} titled={plan.titled} short={plan.short[index]} />
      ))}
      {rest > 0 && (
        <button
          ref={trigger}
          type="button"
          className="acpmux-pr-dock__more"
          aria-label={t("prDock.more", { count: rest })}
          aria-haspopup="dialog"
          aria-expanded={open}
          data-open={open || undefined}
          {...press}
        >
          +{rest}
        </button>
      )}
      <Popover
        open={open && rest > 0}
        onOpenChange={setOpen}
        anchor={trigger.current}
        // Focus stays on +N: a focused first chip would open its hover card over the list. Tab
        // moves into the chips; Escape returns to +N.
        initialFocus={false}
        finalFocus={trigger}
        label={t("prDock.label")}
        side="top"
        className="acpmux-pr-dock__popover"
      >
        <span className="acpmux-pr-dock__list">
          {prs.slice(visible).map((pr) => (
            <PullRequestChip key={pr.url} pr={pr} live={live} titled listed />
          ))}
        </span>
      </Popover>
    </span>
  );
}

/// The hidden sizes the row plans from: the chip's number alone, then its whole title.
function MeasureChip({ pr, live }: { pr: SummaryPullRequest; live: LivePullRequest }) {
  const title = usePullRequestTitle(pr, live);
  return (
    <>
      <span data-measure="number">#{pr.number}</span>
      <span data-measure="title">{title}</span>
    </>
  );
}

/// One chip: its number, and its title when the row has room for a readable one. Its hover card
/// gives the whole title, repository and state.
function PullRequestChip({
  pr,
  live,
  titled,
  short = false,
  listed = false,
}: {
  pr: SummaryPullRequest;
  live: LivePullRequest;
  titled: boolean;
  /// The whole title fits within the readable minimum (the planner's measurement).
  short?: boolean;
  /// A row of the overflow list: with no title, it names the repository instead.
  listed?: boolean;
}) {
  const title = usePullRequestTitle(pr, live);
  const state = live?.url === pr.url && live.state ? live.state : pr.state;
  return (
    <PullRequestBar pr={pr} state={state} title={title}>
      <span className="acpmux-pr-dock__number">#{pr.number}</span>
      {titled && title && (
        <span className="acpmux-pr-dock__title" data-short={short || undefined}>
          {title}
        </span>
      )}
      {listed && !title && <span className="acpmux-pr-dock__repo">{pr.repo}</span>}
    </PullRequestBar>
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
