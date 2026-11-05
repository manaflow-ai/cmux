// A queued prompt's images, as a row of small thumbnails under its text (ComposerQueue.tsx), as
// Claude's and ChatGPT's apps draw a queued message's pictures (Leo, 2026-10-21: "do queued
// messages have pics?": acpmux kept and sent the screenshot, the row showed only its text). Each
// opens the image viewer; while the prompt is edited each has a remove control, and the edit then
// keeps only the images left.
//
// The row stays compact: one tile per attachment, never one per image block. A video's frames
// (composer/videoPrompt.ts, each a `<video> frame at <time>` image the agent reads) are one tile with
// its first frame, a play glyph and its length, and past one row of tiles the rest is one "+N"
// (Leo, 2026-11-05, after three screen recordings drew 23 frames in three rows over the composer:
// "uh this was a weird preview idk i guess i accidentally queued?"). Removing a video's tile in an
// edit drops all its frames.
import React, { useContext, useEffect, useRef, useState } from "react";
import type { QueuedPromptImage } from "./model";
import type { Translate } from "./i18n";
import { imageLabel } from "./imageLabel";
import { ImageViewerContext } from "./conversation/imageViewerContext";
import { isVideoFrameName } from "./composer/videoPrompt";
import { formatDuration } from "./chips/ReplyMedia";
import { PlayTriangle } from "./conversation/icons";

/// The most tiles a row draws when not edited: past it, the last place is "+N".
export const QUEUED_TILES_SHOWN = 6;

/// One tile of a queued prompt: an image, or a video with every frame of it the prompt carries.
export type QueuedTile =
  | { kind: "image"; image: QueuedPromptImage }
  | { kind: "video"; name: string; poster: QueuedPromptImage; ids: string[]; durationMs?: number };

/// `images` as tiles, in order: a video's frames go in one tile, at its first frame. A video's frames
/// come together and in time order (composer/videoPrompt.ts `videoFrameBlocks`), so a frame joins
/// the tile just before it only when that tile is its video's and the time goes on; two videos of
/// one name stay two tiles. `lengths` gives a video's length by its name, where the prompt's parts
/// name it.
export function queuedTiles(images: readonly QueuedPromptImage[], lengths?: ReadonlyMap<string, number>): QueuedTile[] {
  const tiles: QueuedTile[] = [];
  let lastAt = -1;
  for (const image of images) {
    const frame = isVideoFrameName(image.name) ? image.name!.match(/^(.+) frame at ([\d:.]+)$/) : null;
    if (!frame) {
      tiles.push({ kind: "image", image });
      continue;
    }
    const name = frame[1]!;
    const at = frame[2]!.split(":").reduce((total, part) => total * 60 + Number(part), 0);
    const last = tiles.at(-1);
    if (last?.kind === "video" && last.name === name && at > lastAt) last.ids.push(image.id);
    else {
      const durationMs = lengths?.get(name);
      tiles.push({ kind: "video", name, poster: image, ids: [image.id], ...(durationMs ? { durationMs } : {}) });
    }
    lastAt = at;
  }
  return tiles;
}

export function QueuedImages({
  images,
  lengths,
  t,
  read,
  onRemove,
  onLeave,
  onCancel,
}: {
  images: readonly QueuedPromptImage[];
  /// The prompt's videos' lengths by name (its parts' `video`), for their tiles.
  lengths?: ReadonlyMap<string, number>;
  t: Translate;
  /// Reads an image acpmux keeps by its id (`_acpmux/attachment`), for one the pane has no bytes for.
  read?(id: string): Promise<string | undefined>;
  /// While the prompt is edited: drops the image from it. Absent otherwise.
  onRemove?(id: string): void;
  /// While the prompt is edited: focus left the remove controls for somewhere outside the row, which
  /// saves the edit as a blur of its field does.
  onLeave?(): void;
  /// While the prompt is edited: Esc on an image or its remove control, which cancels the edit as
  /// Esc in its field does.
  onCancel?(): void;
}) {
  const editing = onRemove !== undefined;
  // Esc cancelled the edit: the blur its focus move brings is not a save.
  const cancelled = useRef(false);
  const escape = editing
    ? (event: React.KeyboardEvent) => {
        if (event.key !== "Escape" || event.nativeEvent.isComposing) return;
        event.preventDefault();
        event.stopPropagation();
        cancelled.current = true;
        onCancel?.();
        cancelled.current = false;
      }
    : undefined;
  if (images.length === 0) return null;
  const tiles = queuedTiles(images, lengths);
  // While edited, every tile shows, so each can be removed.
  const capped = !editing && tiles.length > QUEUED_TILES_SHOWN;
  const shown = capped ? tiles.slice(0, QUEUED_TILES_SHOWN - 1) : tiles;
  const more = tiles.length - shown.length;
  return (
    <span
      className="acpmux-queued-images"
      onBlur={(event) => {
        if (cancelled.current) return;
        // Staying in the row is the field or another image control; the row itself is leaving.
        const to = event.relatedTarget;
        const row = event.currentTarget.parentElement;
        if (!editing || (to instanceof Node && to !== row && row?.contains(to))) return;
        // Focus moving to another element of the page, or a click on none; not the window losing it.
        if (to || document.hasFocus()) onLeave?.();
      }}
    >
      <span className="acpmux-queued-tiles">
        {shown.map((tile, index) => {
          const image = tile.kind === "video" ? tile.poster : tile.image;
          return (
            <QueuedImage
              // The same picture attached twice has one id, so its copies count up to keep keys unique
              // (removing it drops every copy: the edit keeps images by id).
              key={`${image.id}-${shown.slice(0, index).filter((other) => idOf(other) === image.id).length}`}
              image={image}
              video={tile.kind === "video" ? tile : undefined}
              t={t}
              read={read}
              editing={editing}
              onEscape={escape}
              // An image acpmux has not named yet (sent a moment ago) cannot be kept or dropped by id.
              onRemove={
                onRemove && !image.local
                  ? () => (tile.kind === "video" ? tile.ids : [image.id]).forEach((id) => onRemove(id))
                  : undefined
              }
            />
          );
        })}
      </span>
      {more > 0 && <span className="acpmux-queued-images-more">{t("multiplayer.more", { count: more })}</span>}
    </span>
  );
}

const idOf = (tile: QueuedTile) => (tile.kind === "video" ? tile.poster.id : tile.image.id);

function QueuedImage({
  image,
  video,
  t,
  read,
  editing,
  onEscape,
  onRemove,
}: {
  image: QueuedPromptImage;
  /// The video this tile stands for: `image` is its first frame.
  video?: Extract<QueuedTile, { kind: "video" }>;
  t: Translate;
  read?(id: string): Promise<string | undefined>;
  editing: boolean;
  /// While the prompt is edited: Esc on the image or its remove control cancels the edit, as Esc in
  /// its field does.
  onEscape?(event: React.KeyboardEvent): void;
  onRemove?(): void;
}) {
  // While the prompt is edited its field keeps focus, so a click on an image does not end the edit
  // (it saves on blur).
  const keepFocus = editing ? (event: React.MouseEvent) => event.preventDefault() : undefined;
  const openImage = useContext(ImageViewerContext);
  const [loaded, setLoaded] = useState<{ id: string; src?: string }>();
  const src = image.src ?? (loaded?.id === image.id ? loaded.src : undefined);
  // Whether its picture drew, for chat_state (queuedRowsState.ts): the slot says how far it got.
  const [drawn, setDrawn] = useState<{ src: string; ok: boolean }>();
  const reading = !image.src && read !== undefined && loaded?.id !== image.id;
  const thumbnail = !src
    ? reading
      ? "reading"
      : "missing"
    : drawn?.src !== src
      ? "loading"
      : drawn?.ok
        ? "loaded"
        : "failed";
  useEffect(() => {
    if (image.src || !read) return;
    let live = true;
    read(image.id).then(
      (url) => live && setLoaded({ id: image.id, src: url }),
      () => live && setLoaded({ id: image.id }),
    );
    return () => {
      live = false;
    };
  }, [image.id, image.src, read]);
  const length = video?.durationMs ? formatDuration(video.durationMs / 1000) : undefined;
  const label = video ? [video.name, length].filter(Boolean).join(", ") : imageLabel(t, { name: image.name });
  return (
    <span
      className="acpmux-queued-image-slot"
      data-image-id={image.id}
      data-thumbnail={thumbnail}
      data-video={video ? "" : undefined}
    >
      <button
        type="button"
        className="acpmux-queued-image"
        /* tooltip-allow: an image thumbnail shows no name */ title={label}
        aria-label={label || t("image.view")}
        disabled={!src}
        onMouseDown={keepFocus}
        // ui-allow: the edit's Esc, from an image (the field's Esc is QueuedEdit's).
        onKeyDown={onEscape}
        onClick={() => src && openImage?.(src, label)}
      >
        {src ? (
          <img
            src={src}
            alt=""
            decoding="async"
            onLoad={() => setDrawn({ src, ok: true })}
            onError={() => setDrawn({ src, ok: false })}
          />
        ) : (
          <span className="acpmux-queued-image-empty" />
        )}
        {/* The composer's own video glyph and length (composerAttachments.css), so the tile reads as
            the video chip that was sent. */}
        {video && (
          <span className="acpmux-attachment-video-play" aria-hidden="true">
            <PlayTriangle />
          </span>
        )}
        {length && (
          <span className="acpmux-attachment-video-length" aria-hidden="true">
            {length}
          </span>
        )}
      </button>
      {onRemove && (
        <button
          type="button"
          className="acpmux-queued-image-remove"
          aria-label={t("composer.removeAttachment", { name: label })}
          title={t("composer.removeAttachment", { name: label })}
          onMouseDown={keepFocus}
          // ui-allow: the edit's Esc, from an image's remove control (the field's Esc is QueuedEdit's).
          onKeyDown={onEscape}
          onClick={(event) => {
            // Removed from the keyboard: focus goes back to the edit's field, where Return saves.
            if (document.activeElement === event.currentTarget) {
              const field = event.currentTarget.closest(".acpmux-queued-images")?.parentElement;
              field?.querySelector<HTMLElement>(".acpmux-queued-edit")?.focus();
            }
            onRemove();
          }}
        >
          <svg viewBox="0 0 16 16" width="8" height="8" aria-hidden="true">
            <path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
      )}
    </span>
  );
}
