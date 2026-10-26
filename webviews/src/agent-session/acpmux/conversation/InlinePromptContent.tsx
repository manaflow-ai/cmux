// The ordered content of a sent prompt when the composer kept attachments in the text.
// Text and every attachment stay in their ACP order. Legacy rows continue to use PromptText and
// SentImages in UserBubble; this component is only selected for an explicit inlineParts record.
import { memo, useContext, useState } from "react";
import type { PromptContentPart } from "../model";
import { useT } from "../i18n";
import { ImageIcon, PlayTriangle } from "./icons";
import { ImageViewerContext } from "./imageViewerContext";
import { useStableImage } from "./imageEntries";
import { TurnActionsContext } from "./turnActions";

type InlineAttachment = Extract<PromptContentPart, { kind: "file" | "document" | "audio" | "pasted" }>;
type InlinePastedPart = InlineAttachment & { kind: "pasted" };

export function InlinePromptContent({
  rowId,
  parts,
  show,
}: {
  rowId: string;
  parts: readonly PromptContentPart[];
  show: (text: string) => string;
}) {
  return (
    <div className="cv-user__inline" data-inline-prompt="true" data-row-id={rowId}>
      {parts.map((part, index) => (
        <InlinePart key={`${part.kind}-${index}`} part={part} show={show} />
      ))}
    </div>
  );
}

function InlinePart({ part, show }: { part: PromptContentPart; show: (text: string) => string }) {
  if (part.kind === "text")
    return (
      <span className="cv-user__inline-text" data-inline-kind="text">
        {show(part.text)}
      </span>
    );
  if (part.kind === "image") return <InlineImage image={part} />;
  if (part.kind === "pasted") return <InlinePasted part={part as InlinePastedPart} />;
  if (part.video) return <InlineVideo part={part} />;
  return <InlineFile part={part} />;
}

const InlineImage = memo(function InlineImage({ image }: { image: Extract<PromptContentPart, { kind: "image" }> }) {
  const t = useT();
  const { promptImage } = useContext(TurnActionsContext);
  const viewer = useContext(ImageViewerContext);
  const source = image.src ? { src: image.src } : { id: image.id, read: promptImage };
  const shown = useStableImage(source, image);
  const [failed, setFailed] = useState(false);
  const label = image.name || t("image.viewer");
  const media =
    shown.src && !failed ? (
      <img
        className={shown.fresh ? "cv-user__inline-image cv-enter" : "cv-user__inline-image"}
        src={shown.src}
        alt={label}
        width={shown.width ?? image.width ?? 1}
        height={shown.height ?? image.height ?? 1}
        decoding={shown.decoded ? "sync" : "async"}
        onError={() => setFailed(true)}
        onLoad={(event) => {
          if (!event.currentTarget.naturalWidth || !event.currentTarget.naturalHeight) setFailed(true);
          else shown.onLoad(event);
        }}
      />
    ) : shown.status === "loading" ? (
      <span className="cv-user__inline-image-placeholder" aria-hidden="true" />
    ) : (
      <span className="cv-user__inline-image-failed">
        <ImageIcon size={16} />
        <span>{t("image.failed")}</span>
      </span>
    );
  if (!viewer || !shown.src || failed) return <span className="cv-user__inline-media" data-inline-kind="image">{media}</span>;
  return (
    <button
      type="button"
      className="cv-user__inline-media cv-user__inline-media-button"
      data-inline-kind="image"
      draggable
      title={label}
      aria-label={label || t("image.view")}
      onClick={() => viewer(shown.src!, label)}
    >
      {media}
    </button>
  );
});

function InlineVideo({ part }: { part: Extract<PromptContentPart, { kind: "file" | "document" | "audio" | "pasted" }> }) {
  const name = part.name || "video";
  const poster = part.video?.poster;
  const duration = part.video && part.video.durationMs > 0 ? formatDuration(part.video.durationMs) : undefined;
  return (
    <span className="cv-user__inline-media cv-user__inline-video" data-inline-kind="video" title={name}>
      {poster ? <img className="cv-user__inline-image" src={poster} alt="" /> : <span className="cv-user__inline-video-fallback"><PlayTriangle size={18} /></span>}
      <span className="cv-user__inline-video-play" aria-hidden="true"><PlayTriangle size={16} /></span>
      {duration && <span className="cv-user__inline-video-length" aria-hidden="true">{duration}</span>}
    </span>
  );
}

function InlineFile({ part }: { part: Extract<PromptContentPart, { kind: "file" | "document" | "audio" | "pasted" }> }) {
  return (
    <span className="acpmux-attachment acpmux-attachment-file cv-user__inline-file" data-inline-kind={part.kind}>
      <span>{part.name}</span>
      {part.size !== undefined && <span className="acpmux-attachment-link-note">{formatBytes(part.size)}</span>}
    </span>
  );
}

function InlinePasted({ part }: { part: InlinePastedPart }) {
  const text = part.text ?? "";
  const lines = Math.max(1, text.split(/\r?\n/).length);
  return (
    <span className="cv-user__paste-block cv-user__inline-pasted" data-inline-kind="pasted">
      <span className="acpmux-attachment acpmux-attachment-file cv-user__paste">
        <span className="cv-user__paste-name">{part.name}</span>
        <span className="acpmux-attachment-link-note cv-user__paste-lines">{lines} {lines === 1 ? "line" : "lines"}</span>
      </span>
    </span>
  );
}

function formatDuration(durationMs: number): string {
  const total = Math.max(1, Math.round(durationMs / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = String(total % 60).padStart(2, "0");
  return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${seconds}` : `${minutes}:${seconds}`;
}

function formatBytes(size: number): string {
  if (!Number.isFinite(size) || size <= 0) return "";
  if (size < 1024) return `${Math.round(size)} B`;
  if (size < 1024 * 1024) return `${Math.round(size / 1024)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}
