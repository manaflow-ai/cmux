// One hover card for every link in the transcript (Leo 2026-10-20): a reply's web link, a pull
// request chip and the pull request bars above the composer. Its head is one compact row: the
// site's icon or the GitHub mark inline beside the title (the page title cmux already has, else
// the host; a pull request's own title), then Open (a cmux tab) and Open in. A web link adds its
// address with secret-looking values as ••• (linkDisplay.ts); a pull request adds its state,
// author, checks and files instead (PullRequestCard.tsx), and no address line: its head and
// `owner/repo#N` already say where it is (Leo 2026-10-21, "the styling/layout/spacing could be a bit
// better"). It sits on the tooltip's frosted glass (styles.css .cv-link-preview).
import type { PointerEvent, ReactNode } from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { OpenInMenu } from "../previewCard/OpenInMenu";
import { useT } from "../i18n";
import { callChipHost } from "./host";
import { redactUrlText } from "./linkDisplay";
import { PullRequestCardBody, type KnownPullRequest } from "./PullRequestCard";
import type { HoverCard } from "./useHoverCard";

/// `href`'s host, or `href` when it doesn't parse.
export function linkHost(href: string): string {
  try {
    return new URL(href).host;
  } catch {
    return href;
  }
}

export function LinkHoverCard({
  id,
  href,
  anchor,
  hover,
  mark,
  siteTitle,
  pullRequest,
  side,
}: {
  /// For the link's `aria-describedby` while the card shows.
  id?: string;
  href: string;
  /// The link the card describes; it shows while `hover.open`.
  anchor: HTMLElement | null;
  hover: HoverCard;
  mark: ReactNode;
  /// The page's title as cmux already has it.
  siteTitle?: string;
  /// A pull request link: what the page already knows about it.
  pullRequest?: KnownPullRequest;
  side?: "top" | "bottom";
}) {
  const t = useT();
  const host = linkHost(href);
  // Any http(s) link opens in a cmux tab as a click on it does (`browser.openIn` with cmux's own id,
  // which spends the click's gesture); `browser.open` takes only a turn's local preview page.
  const openInCmux = (url: string) => void callChipHost("browser.openIn", { url, browserId: "cmux" });
  const onOpen = (event: PointerEvent<HTMLButtonElement>) => {
    event.preventDefault();
    event.stopPropagation();
    openInCmux(href);
  };
  const head = (title: string) => (
    <div className="cv-link-preview__head">
      <span className="cv-link-preview__icon">{mark}</span>
      <span className="cv-link-preview__site">{title}</span>
      <button type="button" className="cv-link-preview__open" onClick={onOpen}>
        {t("image.open")}
        <span aria-hidden="true">↗</span>
      </button>
      <OpenInMenu url={href} onOpenInPane={openInCmux} onOpenChange={hover.menuChanged} />
    </div>
  );
  return (
    <AnchoredCard
      id={id}
      anchor={hover.open ? anchor : null}
      className={pullRequest ? "cv-link-preview acpmux-pr-card" : "cv-link-preview"}
      side={side}
      interactive
      // A pull request's page title only repeats its own title: the card is named by its reference.
      ariaLabel={pullRequest ? `${pullRequest.repo}#${pullRequest.number}` : (siteTitle ?? host)}
    >
      <div className="cv-link-preview__content" {...hover.card}>
        {pullRequest ? (
          <PullRequestCardBody url={href} known={pullRequest} open={hover.open} head={head} />
        ) : (
          <>
            {head(siteTitle ?? host)}
            <div className="cv-link-preview__target">{redactUrlText(href)}</div>
          </>
        )}
      </div>
    </AnchoredCard>
  );
}
