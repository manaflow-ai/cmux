// A link in a Home chat as a chip with a hover card (Swift `HomeLinkChipHoverSource` and
// `HomeLinkPreviewCardView`). A web link is the agent pane's own chip (`UrlChip`, with its site and
// pull request card); an app link (a workspace, a tab, an agent chat) or a file path is a chip
// whose card asks the app what the target is now: the quick facts as the card opens, then the
// slower ones (lines, a thumbnail) in place. The card is the shared link card's glass and head
// (linkCard.css), opened by the shared hover intent (useHoverCard). A late answer never lands on
// a card that closed or moved to another link.
import { useEffect, useState } from "react";
import { UrlChip } from "../../../../agent-session/acpmux/chips/LinkChips";
import { useHoverCard } from "../../../../agent-session/acpmux/chips/useHoverCard";
import { chatUnderHoverCard, hoverCardGlass } from "../../../../agent-session/acpmux/chatUnderGlass";
import { Icon } from "../../../../agent-session/acpmux/icons/Icon";
import { AnchoredCard } from "../../../../ui/Tooltip";
import "../../../../agent-session/acpmux/chips/chips.css";
import "../../../../agent-session/acpmux/chips/linkCard.css";
import {
  chipLabel,
  LINK_KIND_ICON,
  linkChipKind,
  type HomeLinkChipKind,
  type HomeLinkPreview,
  type LinkPreviewFetch,
} from "./linkPreview";
import "../cards.css";

export interface HomeLinkChipProps {
  href: string;
  /** The link's text in the message. */
  label: string;
  /** Asks the app for the target's facts (`cmux.home.linkPreview`). */
  fetchPreview: LinkPreviewFetch;
  /** A click: the host opens the app link or path (`link.open`), never the system. */
  onOpen(href: string): void;
}

/** A Home link: a chip for a link Home knows, else the agent pane's web chip. */
export function HomeLinkChip({ href, label, fetchPreview, onOpen }: HomeLinkChipProps) {
  const kind = linkChipKind(href);
  if (!kind || href.startsWith("https:")) return <UrlChip href={href}>{label}</UrlChip>;
  return <AppLinkChip href={href} kind={kind} label={label} fetchPreview={fetchPreview} onOpen={onOpen} />;
}

function AppLinkChip({ href, kind, label, fetchPreview, onOpen }: HomeLinkChipProps & { kind: HomeLinkChipKind }) {
  const hover = useHoverCard();
  const [anchor, setAnchor] = useState<HTMLAnchorElement | null>(null);
  const preview = useLinkPreview(href, kind, hover.open, fetchPreview);
  return (
    <>
      <a
        ref={setAnchor}
        className="cv-link cv-chip hm-link-chip"
        data-kind={kind}
        href={href}
        {...hover.trigger}
        onClick={(event) => {
          event.preventDefault();
          onOpen(href);
        }}
      >
        <Icon name={LINK_KIND_ICON[kind]} size={14} className="cv-chip__icon" />
        <span className="cv-chip__label">{chipLabel(label)}</span>
      </a>
      <AnchoredCard
        anchor={hover.open ? anchor : null}
        className="ui-glass ui-glass-floats cv-link-preview hm-link-preview"
        side="top"
        instant
        interactive
        hoverBridgeId={hover.card["data-cmux-hover-bridge"]}
        under={chatUnderHoverCard}
        underOptions={hoverCardGlass}
        onPointerEnter={hover.card.onPointerEnter}
        onPointerLeave={hover.card.onPointerLeave}
        ariaLabel={preview?.title ?? label}
      >
        <div className="cv-link-preview__content" {...hover.card}>
          <LinkPreviewBody preview={preview ?? { kind, title: label }} />
        </div>
      </AnchoredCard>
    </>
  );
}

/** The card's facts while it is open: the quick ones, then the details in place. An answer for a
 * card that closed (or a link that changed) is dropped. */
export function useLinkPreview(
  href: string,
  kind: HomeLinkChipKind,
  open: boolean,
  fetchPreview: LinkPreviewFetch,
): HomeLinkPreview | undefined {
  // Each answer is kept with the link it answers, so a chip that now shows another link (or
  // closes) never draws the last link's facts while its own are on the way.
  const [answer, setAnswer] = useState<{ request: string; preview: HomeLinkPreview } | undefined>();
  const request = `${kind}\n${href}`;
  useEffect(() => {
    if (!open) return;
    let current = true;
    const keep = (preview: HomeLinkPreview | null | undefined) => {
      if (preview && current) setAnswer({ request, preview });
    };
    void fetchPreview({ url: href, kind, details: false })
      .then((quick) => {
        if (!current) return;
        keep(quick);
        return fetchPreview({ url: href, kind, details: true });
      })
      .then(keep)
      .catch(() => undefined);
    return () => {
      current = false;
    };
  }, [href, kind, open, fetchPreview, request]);
  return open && answer?.request === request ? answer.preview : undefined;
}

/** The card's body: the kind's icon and the live title with its state, where the target is, a few
 * content lines, then a thumbnail when there is one. No empty row for a fact it lacks. */
export function LinkPreviewBody({ preview }: { preview: HomeLinkPreview }) {
  const lines = preview.lines ?? [];
  return (
    <div className="hm-link-preview__body">
      <div className="cv-link-preview__head">
        <span className="cv-link-preview__icon">
          <Icon name={LINK_KIND_ICON[preview.kind]} size={16} />
        </span>
        <span className="cv-link-preview__titles">
          <span className="cv-link-preview__site hm-link-preview__title">{preview.title}</span>
          {preview.place && <span className="cv-link-preview__target">{preview.place}</span>}
        </span>
        {preview.status && (
          <span className="hm-link-preview__status" data-tone={preview.statusTone ?? "secondary"}>
            {preview.status}
          </span>
        )}
      </div>
      {lines.length > 0 && (
        <div className="hm-link-preview__lines" data-mono={preview.monospaced ? "" : undefined}>
          {lines.slice(0, 6).join("\n")}
        </div>
      )}
      {preview.thumbnail && <img className="hm-link-preview__thumbnail" src={preview.thumbnail} alt="" />}
    </div>
  );
}
