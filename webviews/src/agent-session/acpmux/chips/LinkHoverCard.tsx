// One hover card for every link in the transcript (Leo 2026-10-20): a reply's web link, a pull
// request chip and the pull request bars above the composer. Its head is the site's icon, the page
// title cmux already has (else the host), Open (a cmux tab) and Open in; its foot is the host and
// the full address with secret-looking values as ••• (linkDisplay.ts). A pull request adds its full
// title, state, author and checks between them (PullRequestCard.tsx). It sits on the tooltip's
// frosted glass (styles.css .cv-link-preview).
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
  href,
  anchor,
  hover,
  mark,
  siteTitle,
  pullRequest,
  side,
}: {
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
  const onOpen = (event: PointerEvent<HTMLButtonElement>) => {
    event.preventDefault();
    event.stopPropagation();
    void callChipHost("browser.open", { url: href });
  };
  return (
    <AnchoredCard
      anchor={hover.open ? anchor : null}
      className={pullRequest ? "cv-link-preview acpmux-pr-card" : "cv-link-preview"}
      side={side}
      interactive
      ariaLabel={siteTitle ?? host}
    >
      <div {...hover.card}>
        <div className="cv-link-preview__head">
          <span className="cv-link-preview__icon">{mark}</span>
          <span className="cv-link-preview__site">{siteTitle ?? host}</span>
          <button type="button" className="cv-link-preview__open" onClick={onOpen}>
            {t("image.open")}
            <span aria-hidden="true">↗</span>
          </button>
          <OpenInMenu
            url={href}
            onOpenInPane={(url) => void callChipHost("browser.open", { url })}
            onOpenChange={hover.menuChanged}
          />
        </div>
        {pullRequest && <PullRequestCardBody url={href} known={pullRequest} open={hover.open} />}
        <div className="cv-link-preview__target">
          {host} · {redactUrlText(href)}
        </div>
      </div>
    </AnchoredCard>
  );
}
