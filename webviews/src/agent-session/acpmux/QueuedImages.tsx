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

/// One video the prompt carries, as its file part says (`video`): its name, length and how many
/// frames it sent, for its tile.
export type QueuedVideo = { name: string; durationMs?: number; frames?: number };

/// `images` as tiles, in order: a video's frames go in one tile, at its first frame. A video's frames
/// come together and in time order (composer/videoPrompt.ts `videoFrameBlocks`), so a frame joins
/// the tile just before it when that tile is its video's and has frames left. `videos`, the prompt's
/// videos in order, gives each tile its own video's length and frame count, so two videos of one
/// name stay two tiles even when the times go on across them; a video the parts don't describe (a
/// record from before a reload) ends where the time stops going on or passes its length (a frame's name rounds it to a tenth).
export function queuedTiles(images: readonly QueuedPromptImage[], videos?: readonly QueuedVideo[]): QueuedTile[] {
  const tiles: QueuedTile[] = [];
  const unused = [...(videos ?? [])];
  let lastAt = -1;
  let left: number | undefined;
  let lengthMs: number | undefined;
  for (const image of images) {
    const frame = isVideoFrameName(image.name) ? image.name!.match(/^(.+) frame at ([\d:.]+)$/) : null;
    if (!frame) {
      tiles.push({ kind: "image", image });
      continue;
    }
    const name = frame[1]!;
    const at = frame[2]!.split(":").reduce((total, part) => total * 60 + Number(part), 0);
    const last = tiles.at(-1);
    const goesOn =
      left === undefined ? at > lastAt && (lengthMs === undefined || at * 1000 <= lengthMs + 50) : left > 0;
    if (last?.kind === "video" && last.name === name && goesOn) {
      last.ids.push(image.id);
      if (left !== undefined) left--;
    } else {
      const index = unused.findIndex((video) => video.name === name);
      const video = index < 0 ? undefined : unused.splice(index, 1)[0];
      const durationMs = video?.durationMs;
      tiles.push({ kind: "video", name, poster: image, ids: [image.id], ...(durationMs ? { durationMs } : {}) });
      left = video?.frames ? video.frames - 1 : undefined;
      lengthMs = durationMs;
    }
    lastAt = at;
  }
  return tiles;
}

export function QueuedImages({
  images,
  videos,
  dropped,
  t,
  read,
  onRemove,
  onLeave,
  onCancel,
}: {
  images: readonly QueuedPromptImage[];
  /// The prompt's videos in order (its parts' `video`), for their tiles.
  videos?: readonly QueuedVideo[];
  /// While the prompt is edited: the images removed so far. Their tiles go, and the rest keep the
  /// videos they had (each video's tile is made from all the prompt's images first).
  dropped?: ReadonlySet<string>;
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
  const tiles = queuedTiles(images, videos).filter((tile) =>
    tile.kind === "video" ? !tile.ids.every((id) => dropped?.has(id)) : !dropped?.has(tile.image.id),
  );
  if (tiles.length === 0) return null;
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
        {/* One corner chip, the play glyph and the length, on the composer's video scrim
            (composerAttachments.css): a 36px tile has no room for a centred glyph as well. */}
        {video && (
          <span className="acpmux-attachment-video-length acpmux-queued-video" aria-hidden="true">
            <PlayTriangle size={12} />
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
