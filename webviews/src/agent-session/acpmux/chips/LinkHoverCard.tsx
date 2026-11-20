// One hover card for every link in the transcript (Leo 2026-10-20): a reply's web link, a pull
// request chip and the pull request bars above the composer. Its head is one compact row: the
// site's icon (a pull request's glyph in its state's colour) inline beside the title (the page
// title cmux already has, else the host; a pull request's own title), then one quiet split button:
// Open (a cmux tab) and its chevron, which offers the other browsers. A web link's address, with secret-looking values as •••
// (linkDisplay.ts), sits under its title when it says more than the host already does; a pull
// request has no address line, and adds its author, checks and files (PullRequestCard.tsx). Tight
// spacing, no dividers, on the liquid glass (.ui-glass; styles.css .cv-link-preview; Leo
// 2026-10-21: "the styling/layout/spacing could be a bit better"). It shows in the frame it opens
// in, with no fade and no rise (`instant`; Leo 2026-11-06: "it plays this really laggy, slow
// animation for the GitHub ones"): its in-place blur over the chat (chatUnderGlass.ts) follows the
// card's rect, so a 2 px rise rewrote the transcript's blur filter on every frame of the fade, and
// the display compositor redrew the whole filtered transcript each time. It leaves with the
// tooltip's short fade, which moves nothing. A menu opens on the click with no fade either.
import { useEffect, type PointerEvent, type ReactNode } from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { OpenInMenu } from "../previewCard/OpenInMenu";
import { useT } from "../i18n";
import { callChipHost } from "./host";
import { redactUrlText } from "./linkDisplay";
import { PullRequestCardBody, type KnownPullRequest } from "./PullRequestCard";
import type { HoverCard } from "./useHoverCard";
// The card's rules, for every page that shows it (the agent pane, the changelog).
import "./linkCard.css";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { chatUnderHoverCard, hoverCardGlass } from "../chatUnderGlass";
import { linkHost } from "./linkHoverCardModel";
import { githubItemRef } from "./pullRequestCardModel";
import { prefetchPullRequest } from "./pullRequestStore";
/// `href` with its secrets masked, unless it says no more than `host` (the head names the host).
function addressBeyond(href: string, host: string): string | undefined {
  const address = redactUrlText(href);
  return address.replace(/^[a-z][\w+.-]*:\/\//i, "").replace(/\/$/, "") === host ? undefined : address;
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
  // Read only: the link opens in the reader's own browser as a plain link; cmux's tabs are the owner's.
  const readOnly = useTranscriptReadOnly();
  const host = linkHost(href);
  // A pull request's or issue's card asks the host on hover intent, when the pointer reaches the
  // link, so the read runs during the dwell and the card opens with it (pullRequestStore.ts).
  const item = pullRequest && !readOnly ? (githubItemRef(href)?.url ?? href) : undefined;
  useEffect(() => {
    if (!item) return;
    const intent = hover.intent;
    intent.current = () => prefetchPullRequest(item);
    return () => {
      intent.current = undefined;
    };
  }, [item, hover.intent]);
  // Any http(s) link opens in a cmux tab as a click on it does (`browser.openIn` with cmux's own id,
  // which spends the click's gesture); `browser.open` takes only a turn's local preview page.
  const openInCmux = (url: string) => void callChipHost("browser.openIn", { url, browserId: "cmux" });
  const onOpen = (event: PointerEvent<HTMLButtonElement>) => {
    event.preventDefault();
    event.stopPropagation();
    openInCmux(href);
  };
  const head = (title: string, glyph: ReactNode = mark, address?: string) => (
    <div className="cv-link-preview__head">
      <span className="cv-link-preview__icon">{glyph}</span>
      <span className="cv-link-preview__titles">
        <span className="cv-link-preview__site">{title}</span>
        {address && <span className="cv-link-preview__target">{address}</span>}
      </span>
      {!readOnly && (
        // One split control (Leo 2026-11-07: "the open and open in, why don't we just combine both
        // of those?"): Open takes the click to a cmux tab, the chevron offers the other targets.
        <span className="cv-link-preview__split">
          <button type="button" className="cv-link-preview__open" onClick={onOpen}>
            {t("image.open")}
            <span aria-hidden="true">↗</span>
          </button>
          <OpenInMenu url={href} onOpenInPane={openInCmux} onOpenChange={hover.menuChanged} chevron />
        </span>
      )}
    </div>
  );
  return (
    <AnchoredCard
      id={id}
      anchor={hover.open ? anchor : null}
      className={
        pullRequest
          ? "ui-glass ui-glass-floats cv-link-preview acpmux-pr-card"
          : "ui-glass ui-glass-floats cv-link-preview"
      }
      side={side}
      instant
      interactive
      hoverBridgeId={hover.card["data-cmux-hover-bridge"]}
      under={chatUnderHoverCard}
      underOptions={hoverCardGlass}
      onPointerEnter={hover.card.onPointerEnter}
      onPointerLeave={hover.card.onPointerLeave}
      // A pull request's page title only repeats its own title: the card is named by its reference.
      ariaLabel={pullRequest ? `${pullRequest.repo}#${pullRequest.number}` : (siteTitle ?? host)}
    >
      <div className="cv-link-preview__content" {...hover.card}>
        {pullRequest ? (
          <PullRequestCardBody url={href} known={pullRequest} open={hover.open} head={head} />
        ) : (
          head(siteTitle ?? host, mark, addressBeyond(href, host))
        )}
      </div>
    </AnchoredCard>
  );
}
