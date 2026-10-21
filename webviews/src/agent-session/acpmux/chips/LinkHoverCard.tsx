// One hover card for every link in the transcript (Leo 2026-10-20): a reply's web link, a pull
// request chip and the pull request bars above the composer. Its head is the site's icon, the page
// title cmux already has (else the host), Open (a cmux tab) and Open in; its foot is the host and
// the full address with secret-looking values as ••• (linkDisplay.ts). A pull request adds its full
// title, state, author and checks between them (PullRequestCard.tsx). It sits on the
// liquid glass (.ui-glass; styles.css .cv-link-preview).
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
  // A pull request's page title repeats its own title, which the body shows: the head names the host.
  const head = pullRequest ? host : (siteTitle ?? host);
  // Any http(s) link opens in a cmux tab as a click on it does (`browser.openIn` with cmux's own id,
  // which spends the click's gesture); `browser.open` takes only a turn's local preview page.
  const openInCmux = (url: string) => void callChipHost("browser.openIn", { url, browserId: "cmux" });
  const onOpen = (event: PointerEvent<HTMLButtonElement>) => {
    event.preventDefault();
    event.stopPropagation();
    openInCmux(href);
  };
  return (
    <AnchoredCard
      id={id}
      anchor={hover.open ? anchor : null}
      className={pullRequest ? "ui-glass cv-link-preview acpmux-pr-card" : "ui-glass cv-link-preview"}
      side={side}
      interactive
      ariaLabel={head}
    >
      <div {...hover.card}>
        <div className="cv-link-preview__head">
          <span className="cv-link-preview__icon">{mark}</span>
          <span className="cv-link-preview__site">{head}</span>
          <button type="button" className="cv-link-preview__open" onClick={onOpen}>
            {t("image.open")}
            <span aria-hidden="true">↗</span>
          </button>
          <OpenInMenu url={href} onOpenInPane={openInCmux} onOpenChange={hover.menuChanged} />
        </div>
        {pullRequest && <PullRequestCardBody url={href} known={pullRequest} open={hover.open} />}
        <div className="cv-link-preview__target">
          {host} · {redactUrlText(href)}
        </div>
      </div>
    </AnchoredCard>
  );
}
