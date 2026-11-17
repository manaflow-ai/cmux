// The transcript's non-text parts as MessagesLab drew them (Swift `HomeMapping.part`): a link the
// sender attached as its preview card (picture, title, site; read from the part, never fetched),
// a shared place as a card with its name and coordinates, a question as its prompt and options
// (`AgentQuestion.transcriptText`), and a mention as a highlighted run of the text it names.
import { useContext, useEffect, useState, type ReactNode } from "react";
import { Icon } from "../../../../agent-session/acpmux/icons/Icon";
import { AttachmentContext } from "../../../home-channels/AttachmentViews";
import { coordinates, questionText } from "../../../home-channels/model";
import type { HomeLinkPreviewPart, HomeLocation, HomeMention, HomeQuestion } from "../../../home-channels/types";
import "../../../../agent-session/acpmux/chips/linkCard.css";
import "./parts.css";

/** A link's host, the title and site a preview without its own shows (Swift `TextParts.host`). */
export function linkHost(url: string): string {
  try {
    return new URL(url).host || url;
  } catch {
    return url;
  }
}

/** The picture of a link preview: a blob of the conversation read by hash (no fetch of the URL). */
function useLinkImage(conversation: string, part: HomeLinkPreviewPart): string | undefined {
  const service = useContext(AttachmentContext);
  const [src, setSrc] = useState<string>();
  const hash = part.image?.hash;
  useEffect(() => {
    if (!service || !hash) return;
    let live = true;
    service.image(conversation, { hash, variant: "original" }).then(
      (value) => live && setSrc(value),
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [service, conversation, hash]);
  return src;
}

/** A `link_preview` part: its card, a click opens the link through the app. */
export function LinkPreviewCard({
  conversation,
  part,
  onOpen,
}: {
  conversation: string;
  part: HomeLinkPreviewPart;
  onOpen?(href: string): void;
}) {
  const image = useLinkImage(conversation, part);
  const host = linkHost(part.url);
  return (
    <a
      className="hm-part-card hm-part-link"
      href={part.url}
      onClick={(event) => {
        event.preventDefault();
        onOpen?.(part.url);
      }}
    >
      {part.image && (
        <span className="hm-part-link__image" data-loaded={image ? "" : undefined}>
          {image && <img src={image} alt="" />}
        </span>
      )}
      <span className="cv-link-preview__head hm-part-card__head">
        <span className="cv-link-preview__icon">
          <Icon name="link.web" size={16} />
        </span>
        <span className="cv-link-preview__titles">
          <span className="cv-link-preview__site">{part.title ?? host}</span>
          <span className="cv-link-preview__target">{part.site ?? host}</span>
        </span>
      </span>
    </a>
  );
}

/** A `location` part: the place's name over its coordinates. */
export function LocationCard({ part }: { part: HomeLocation }) {
  return (
    <div className="hm-part-card hm-part-location">
      <span className="cv-link-preview__head hm-part-card__head">
        <span className="cv-link-preview__icon">
          <Icon name="location" size={16} />
        </span>
        <span className="cv-link-preview__titles">
          {part.label && <span className="cv-link-preview__site">{part.label}</span>}
          <span className="cv-link-preview__target">{coordinates(part)}</span>
        </span>
      </span>
    </div>
  );
}

/** A question that is not a permission card: its words as the native transcript showed them. */
export function QuestionText({ part }: { part: HomeQuestion }) {
  return <span className="mt-text">{questionText(part)}</span>;
}

/** What a place copies (Swift `HomeContentMenu.partItems`): its name, then its coordinates. */
export const locationCopyText = (part: HomeLocation): string =>
  [part.label, coordinates(part)].filter(Boolean).join("\n");

/** `text` with its mentions (UTF-16 ranges) drawn as highlighted runs (Swift `TextRun.mention`).
 * `rest` draws the text between them (links as chips). Overlapping or out-of-range runs are skipped. */
export function mentionedText(
  text: string,
  mentions: readonly HomeMention[],
  names: (participant: string) => string | undefined,
  rest: (piece: string, at: number) => ReactNode = (piece) => piece,
): ReactNode[] {
  const out: ReactNode[] = [];
  let at = 0;
  for (const mention of [...mentions].sort((a, b) => a.start - b.start)) {
    const end = mention.start + mention.length;
    if (mention.start < at || mention.length <= 0 || end > text.length) continue;
    if (mention.start > at) out.push(rest(text.slice(at, mention.start), at));
    out.push(
      <span key={`m${mention.start}`} className="mt-mention" title={names(mention.participant)}>
        {text.slice(mention.start, end)}
      </span>,
    );
    at = end;
  }
  if (at < text.length) out.push(rest(text.slice(at), at));
  return out;
}
