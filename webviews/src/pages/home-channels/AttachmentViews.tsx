// Attachments in a message and in the composer. A message shows its images as one grid (one image
// large, several in tiles, "+N" past four), each opening the lightbox (arrow keys move, Escape
// closes); a video plays inline with its poster and the browser's controls; any other file is a
// row with its type, size and a download link. The composer shows each file it uploads as a tile
// with its progress where the work is (board principle 6) and a remove button on hover or focus.
import { createContext, useContext, useEffect, useMemo, useRef, useState } from "react";
import { Dialog } from "../../ui/Dialog";
import { DialogButton, keyedIconProps } from "../../ui/DialogButton";
import { KeyboardScope } from "../../ui/KeyboardScope";
import type { Strings } from "../shared/i18n";
import { AttachmentService, attachmentClass, formatBytes, type UploadProgress } from "./attachmentService";
import { HomeIcon } from "./icons";
import type { HomeAttachment } from "./types";

/** The page's attachment service (absent: attachments show as named rows only). */
export const AttachmentContext = createContext<AttachmentService | undefined>(undefined);

/** Most image tiles shown in a message; the last one counts the rest. */
const GRID_TILES = 4;

/** A data URL (or URL) of one image variant: `src` once loaded, `failed` when this host cannot read
 * it (an owner without attachment reads here, a record that is gone). */
function useImage(
  conversation: string,
  part: HomeAttachment,
  prefer: "preview" | "original",
): { src?: string; failed: boolean } {
  const service = useContext(AttachmentContext);
  const [state, setState] = useState<{ src?: string; failed: boolean }>({ failed: !service });
  const variant = prefer === "preview" && part.preview ? "preview" : "original";
  useEffect(() => {
    if (!service) return;
    let live = true;
    const load =
      variant === "original" && !AttachmentService.inline(part.byteCount)
        ? service.url(conversation, part.hash, "original", part.name)
        : service.image(conversation, { hash: part.hash, variant });
    load.then(
      (src) => live && setState({ src, failed: false }),
      () => live && setState({ failed: true }),
    );
    return () => {
      live = false;
    };
  }, [service, conversation, part.hash, part.name, part.byteCount, variant]);
  return state;
}

/** The attachment parts of one message, grouped as they show. */
export function MessageAttachments({
  conversation,
  parts,
  strings,
}: {
  conversation: string;
  parts: readonly HomeAttachment[];
  strings: Strings;
}) {
  const images = parts.filter((part) => attachmentClass(part.mimeType) === "image");
  const videos = parts.filter((part) => attachmentClass(part.mimeType) === "video");
  const files = parts.filter((part) => !images.includes(part) && !videos.includes(part));
  const [open, setOpen] = useState<number>();
  return (
    <div className="hc-attachments">
      {images.length > 0 && (
        <div className={`hc-att-grid n${Math.min(images.length, GRID_TILES)}`}>
          {images.slice(0, GRID_TILES).map((part, index) => (
            <ImageTile
              key={`${part.hash}:${index}`}
              conversation={conversation}
              part={part}
              single={images.length === 1}
              more={index === GRID_TILES - 1 ? images.length - GRID_TILES : 0}
              strings={strings}
              onOpen={() => setOpen(index)}
            />
          ))}
        </div>
      )}
      {videos.map((part, index) => (
        <VideoPlayer key={`${part.hash}:${index}`} conversation={conversation} part={part} strings={strings} />
      ))}
      {files.map((part, index) => (
        <FileRow key={`${part.hash}:${index}`} conversation={conversation} part={part} strings={strings} />
      ))}
      {open !== undefined && (
        <Lightbox
          conversation={conversation}
          images={images}
          index={open}
          strings={strings}
          onIndex={setOpen}
          onClose={() => setOpen(undefined)}
        />
      )}
    </div>
  );
}

/** The box an image or video takes before its pixels arrive (no layout jump). */
function frame(part: HomeAttachment, maxWidth: number, maxHeight: number): { width: number; height: number } {
  const width = part.width ?? 4;
  const height = part.height ?? 3;
  const scale = Math.min(1, maxWidth / width, maxHeight / height);
  return { width: Math.round(width * scale), height: Math.round(height * scale) };
}

function ImageTile({
  conversation,
  part,
  single,
  more,
  strings,
  onOpen,
}: {
  conversation: string;
  part: HomeAttachment;
  single: boolean;
  more: number;
  strings: Strings;
  onOpen(): void;
}) {
  const { src, failed } = useImage(conversation, part, "preview");
  const size = single ? frame(part, 360, 280) : undefined;
  return (
    <button
      type="button"
      className={`hc-att-image${single ? " single" : ""}${src ? "" : failed ? " failed" : " loading"}`}
      style={size}
      aria-label={part.name}
      /* tooltip-allow: a loaded image shows no name; the name shows only once it fails */
      title={part.name}
      disabled={failed}
      onClick={onOpen}
    >
      {src && <img src={src} alt={part.name} draggable={false} />}
      {failed && (
        <span className="hc-att-unread">
          <span className="hc-att-name">{part.name}</span>
          <span className="hc-att-meta">{formatBytes(part.byteCount)}</span>
        </span>
      )}
      {more > 0 && <span className="hc-att-more">{strings.format("attachment.more", String(more))}</span>}
    </button>
  );
}

function VideoPlayer({
  conversation,
  part,
  strings,
}: {
  conversation: string;
  part: HomeAttachment;
  strings: Strings;
}) {
  const service = useContext(AttachmentContext);
  const [src, setSrc] = useState<string>();
  const posterSrc = usePoster(conversation, part);
  const size = frame(part, 480, 320);
  /** The playback position to restore after a new link (the old one ended mid-play). */
  const resume = useRef<{ at: number; tried: number } | undefined>(undefined);
  useEffect(() => {
    if (!service) return;
    let live = true;
    service.url(conversation, part.hash, "original", part.name).then(
      (value) => live && setSrc(value),
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [service, conversation, part.hash, part.name]);
  // A link answers 10 minutes: a player that seeks later gets an error; ask for a new link once a
  // minute at most and go on from the same position.
  const renew = (video: HTMLVideoElement) => {
    if (!service || !src) return;
    const now = Date.now();
    if (resume.current && now - resume.current.tried < 60_000) return;
    resume.current = { at: video.currentTime, tried: now };
    service.url(conversation, part.hash, "original", part.name, true).then(setSrc, () => undefined);
  };
  return (
    <figure className="hc-att-video" style={{ width: size.width }}>
      {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- a user's attached file; it has no caption track. */}
      <video
        src={src}
        poster={posterSrc}
        controls
        preload="metadata"
        playsInline
        width={size.width}
        height={size.height}
        aria-label={part.name}
        onError={(event) => renew(event.currentTarget)}
        onLoadedMetadata={(event) => {
          const at = resume.current?.at;
          if (at) event.currentTarget.currentTime = at;
        }}
      />
      <figcaption>
        <span className="hc-att-name">{part.name}</span>
        <span className="hc-att-meta">
          {[part.durationMs !== undefined ? duration(part.durationMs) : "", formatBytes(part.byteCount)]
            .filter(Boolean)
            .join(" · ")}
        </span>
        {src && (
          <a
            className="hc-att-download"
            href={src}
            download={part.name}
            aria-label={strings.format("attachment.download", part.name)}
          >
            <HomeIcon name="download" />
          </a>
        )}
      </figcaption>
    </figure>
  );
}

/** A video's poster image as a data URL. */
function usePoster(conversation: string, part: HomeAttachment): string | undefined {
  const service = useContext(AttachmentContext);
  const [src, setSrc] = useState<string>();
  useEffect(() => {
    if (!service || !part.poster) return;
    let live = true;
    service.image(conversation, { hash: part.hash, variant: "poster" }).then(
      (value) => live && setSrc(value),
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [service, conversation, part.hash, part.poster]);
  return src;
}

function FileRow({ conversation, part, strings }: { conversation: string; part: HomeAttachment; strings: Strings }) {
  const service = useContext(AttachmentContext);
  const extension = part.name.includes(".") ? part.name.slice(part.name.lastIndexOf(".") + 1).toUpperCase() : "";
  // The link could not be had (the daemon does not answer, the record is gone): the row says so,
  // and the button asks again, instead of a click that does nothing.
  const [failed, setFailed] = useState(false);
  const download = async () => {
    if (!service) return;
    setFailed(false);
    let url: string;
    try {
      url = await service.url(conversation, part.hash, "original", part.name);
    } catch {
      setFailed(true);
      return;
    }
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = part.name;
    anchor.rel = "noopener";
    anchor.click();
  };
  return (
    <div className="hc-att-file">
      <span className="hc-att-file-mark" aria-hidden>
        {extension.slice(0, 4) || <HomeIcon name="attach" />}
      </span>
      <span className="hc-att-file-text">
        <span className="hc-att-name">{part.name}</span>
        {failed ? (
          <span className="hc-att-meta is-failed" role="alert">
            {strings.t("attachment.downloadFailed")}
          </span>
        ) : (
          <span className="hc-att-meta">{formatBytes(part.byteCount)}</span>
        )}
      </span>
      {service && (
        <button
          type="button"
          className="hc-att-download"
          aria-label={strings.format("attachment.download", part.name)}
          onClick={() => void download()}
        >
          <HomeIcon name="download" />
        </button>
      )}
    </div>
  );
}

function Lightbox({
  conversation,
  images,
  index,
  strings,
  onIndex,
  onClose,
}: {
  conversation: string;
  images: readonly HomeAttachment[];
  index: number;
  strings: Strings;
  onIndex(index: number): void;
  onClose(): void;
}) {
  const part = images[index];
  const { src } = useImage(conversation, part, "original");
  const { src: preview } = useImage(conversation, part, "preview");
  const step = (by: number) => onIndex((index + by + images.length) % images.length);
  const closeButton = useRef<HTMLButtonElement | null>(null);
  return (
    <Dialog
      open
      onOpenChange={(open) => !open && onClose()}
      label={part.name}
      className="hc-lightbox"
      backdropClassName="hc-lightbox-backdrop"
      initialFocus={closeButton}
    >
      <KeyboardScope
        className="hc-lightbox-body"
        handleKeyDown={(event) => {
          if (images.length < 2 || (event.key !== "ArrowRight" && event.key !== "ArrowLeft")) return;
          event.preventDefault();
          step(event.key === "ArrowRight" ? 1 : -1);
        }}
      >
        <header className="hc-lightbox-bar">
          <span className="hc-att-name">{part.name}</span>
          <span className="hc-att-meta">
            {images.length > 1 ? `${index + 1} / ${images.length} · ` : ""}
            {formatBytes(part.byteCount)}
          </span>
          <span className="lg-spacer" />
          <DialogButton ref={closeButton} dialogKey="escape" className="hc-text-button" onClick={onClose}>
            {strings.t("lightbox.close")}
          </DialogButton>
        </header>
        <div className="hc-lightbox-stage">
          {images.length > 1 && (
            <button
              type="button"
              className="hc-lightbox-step prev"
              {...keyedIconProps(strings.t("lightbox.previous"), "left")}
              onClick={() => step(-1)}
            >
              <HomeIcon name="chevronLeft" />
            </button>
          )}
          {(src ?? preview) && <img src={src ?? preview} alt={part.name} />}
          {images.length > 1 && (
            <button
              type="button"
              className="hc-lightbox-step next"
              {...keyedIconProps(strings.t("lightbox.next"), "right")}
              onClick={() => step(1)}
            >
              <HomeIcon name="chevronRight" />
            </button>
          )}
        </div>
      </KeyboardScope>
    </Dialog>
  );
}

function duration(ms: number): string {
  const seconds = Math.round(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${String(seconds % 60).padStart(2, "0")}`;
}

/** One file the composer uploads: its progress, then the part a send names. */
export interface PendingAttachment {
  id: string;
  file: File;
  /** A local picture of it while it uploads (a data URL of an image). */
  thumb?: string;
  progress: UploadProgress;
  part?: HomeAttachment;
  error?: string;
}

/** The composer's files, above its field. */
export function AttachmentTray({
  items,
  strings,
  onRemove,
}: {
  items: readonly PendingAttachment[];
  strings: Strings;
  onRemove(id: string): void;
}) {
  if (items.length === 0) return null;
  return (
    <ul className="hc-tray" aria-label={strings.t("attach.add")}>
      {items.map((item) => (
        <TrayItem key={item.id} item={item} strings={strings} onRemove={() => onRemove(item.id)} />
      ))}
    </ul>
  );
}

function TrayItem({ item, strings, onRemove }: { item: PendingAttachment; strings: Strings; onRemove(): void }) {
  const fraction = item.progress.total > 0 ? item.progress.sent / item.progress.total : 0;
  const percent = `${Math.round(fraction * 100)}%`;
  const state = item.error ? "failed" : item.part ? "done" : "uploading";
  const status = item.error ?? (item.part ? formatBytes(item.file.size) : strings.format("attach.uploading", percent));
  const kind = useMemo(() => attachmentClass(item.file.type), [item.file.type]);
  return (
    <li className={`hc-tray-item ${state}`}>
      <span className="hc-tray-thumb" aria-hidden>
        {item.thumb ? <img src={item.thumb} alt="" /> : <HomeIcon name={kind === "video" ? "video" : "attach"} />}
      </span>
      <span className="hc-tray-text">
        <span className="hc-att-name">{item.file.name}</span>
        <span className="hc-att-meta" role={item.error ? "alert" : undefined}>
          {status}
        </span>
      </span>
      {state === "uploading" && (
        <span
          className="hc-tray-bar"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a styled bar; <progress> cannot take the fill span.
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={Math.round(fraction * 100)}
        >
          <span style={{ width: percent }} />
        </span>
      )}
      <button
        type="button"
        className="hc-tray-remove"
        aria-label={strings.format("attach.remove", item.file.name)}
        onClick={onRemove}
      >
        <HomeIcon name="close" />
      </button>
    </li>
  );
}
