// The composer strip's pull requests (ComposerStrip.tsx): the chat's newest one as a compact chip,
// its state glyph, number and title (cut at a fixed width), which opens it as the dock's bar does
// (a link). More than one adds `+N`, whose popover lists them all, each with its dismiss button. A
// strip short of room (`compact`) drops the title. Dismiss is never on the chip: the popover, or
// the chip's context menu.
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { Close } from "../conversation/icons";
import { useHeaderState } from "../header/headerState";
import { useLocationPopover } from "../locationPopover";
import { ContextMenu } from "../../../ui/ContextMenu";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { PULL_REQUEST_BADGES, shownPullRequest } from "../summary/pullRequests";
import type { SummaryPullRequest } from "../summary/sessionSummary";

export function StripPullRequests({
  prs,
  compact,
  onDismiss,
}: {
  /// Newest first, without the dismissed ones.
  prs: readonly SummaryPullRequest[];
  compact: boolean;
  onDismiss(url: string): void;
}) {
  const t = useT();
  const { pullRequest: live } = useHeaderState();
  const newest = prs[0];
  if (!newest) return null;
  const describe = (pr: SummaryPullRequest) => {
    const { state, title, labeled } = shownPullRequest(pr, live);
    const badge = PULL_REQUEST_BADGES[state];
    return { state, title, label: labeled ? (badge ? t(badge) : state) : undefined };
  };
  const top = describe(newest);
  return (
    <span className="acpmux-strip-prs">
      <ContextMenu
        className="acpmux-strip-pr-host"
        targets="own"
        items={[
          {
            id: "dismiss",
            label: t("prDock.dismiss", { number: newest.number }),
            onSelect: () => onDismiss(newest.url),
          },
        ]}
      >
        <a
          className="acpmux-strip-chip acpmux-strip-pr"
          href={newest.url}
          data-state={top.state}
          data-compact={compact ? "" : undefined}
          title={[`#${newest.number}`, top.title, top.label].filter(Boolean).join(" · ")}
        >
          <span className="acpmux-strip-glyph" data-state={top.state}>
            <Icon name="git.pullrequest" size={12} />
          </span>
          <span className="acpmux-strip-number">#{newest.number}</span>
          {!compact && top.title && <span className="acpmux-strip-label acpmux-strip-pr-title">{top.title}</span>}
        </a>
      </ContextMenu>
      {prs.length > 1 && <MorePullRequests prs={prs} describe={describe} onDismiss={onDismiss} />}
    </span>
  );
}

function MorePullRequests({
  prs,
  describe,
  onDismiss,
}: {
  prs: readonly SummaryPullRequest[];
  describe(pr: SummaryPullRequest): { state: string; title: string; label?: string };
  onDismiss(url: string): void;
}) {
  const t = useT();
  const { control, anchor, open, setOpen, side } = useLocationPopover();
  const press = usePopoverTrigger(open, setOpen);
  const more = prs.length - 1;
  return (
    <span ref={control} className="acpmux-strip-more-anchor">
      <button
        type="button"
        className="acpmux-strip-chip acpmux-strip-more"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={t("prDock.more", { count: more })}
        {...press}
      >
        +{more}
      </button>
      <Popover
        open={open}
        onOpenChange={setOpen}
        anchor={open ? anchor : null}
        label={t("prDock.label")}
        className="acpmux-menu acpmux-location-menu acpmux-strip-menu"
        side={side}
        flip={false}
      >
        {prs.map((pr) => {
          const { state, title, label } = describe(pr);
          return (
            <div key={pr.url} className="acpmux-strip-menu-pr">
              <a
                className="acpmux-menu-item acpmux-strip-menu-row"
                href={pr.url}
                data-state={state}
                title={title || undefined}
                onClick={() => setOpen(false)}
              >
                <span className="acpmux-strip-glyph" data-state={state}>
                  <Icon name="git.pullrequest" size={12} />
                </span>
                <span className="acpmux-strip-number">#{pr.number}</span>
                <span className="acpmux-strip-label">{title || pr.repo.split("/").pop()}</span>
                {label && <span className="acpmux-strip-time">{label}</span>}
              </a>
              <button
                type="button"
                className="cv-iconbtn cv-iconbtn--compact acpmux-strip-dismiss"
                aria-label={t("prDock.dismiss", { number: pr.number })}
                title={t("prDock.dismiss", { number: pr.number })}
                onClick={() => {
                  onDismiss(pr.url);
                  if (prs.length <= 2) setOpen(false);
                }}
              >
                <Close size={12} />
              </button>
            </div>
          );
        })}
      </Popover>
    </span>
  );
}
