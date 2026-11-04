// An attached video's chip (Leo, 2026-10-25: "also why dont we have previews of videos we should"):
// its poster in the image chip's tile, a small glass play glyph in its middle and its length in a
// corner, like a reply's video thumbnail (chips/ReplyMedia.tsx). A click plays it in the pane
// (Leo, 2026-11-02: "this i can't play a video preview inside cmux next? i feel like i should be able
// to"): the tile is too small for a player's controls, so the player opens large over the pane
// (chips/ReplyMedia.tsx VideoViewer), playing, with scrub, mute and pause; the host serves the file in
// byte ranges, so any size streams. Quick Look plays it only when the host will not grant it.
// While the host reads it (composer/videoAttachments.ts) the tile spins, in the shape it will have;
// one the host could not read keeps that square with the play glyph and no poster, never a file
// chip's long strip (Leo, 2026-10-26: "not for screen recordings. Don't do it for screen
// recordings. We know it's a video. ... Just do the square. Why do we have these long-ass
// rectangles anyway?").
import { useCallback, useRef, useState, type ReactNode } from "react";
import { callChipHost } from "../chips/host";
import { formatDuration, loadPlayableMedia, VideoViewer } from "../chips/ReplyMedia";
import { PlayTriangle, Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import type { VideoInfo } from "./videoAttachments";

export function VideoAttachmentTile({
  name,
  title = name,
  video,
  reading = !video,
  remove,
  onPlay,
}: {
  name: string;
  /// The poster's tooltip: its name, with the line naming where it came from (SourceBadge.tsx).
  title?: string;
  /// Unset while the host reads it, or when it could not (`reading` false).
  video: VideoInfo | undefined;
  /// The host is still reading it: the tile spins.
  reading?: boolean;
  remove: ReactNode;
  onPlay(): void;
}) {
  const t = useT();
  if (!video && reading)
    return (
      <div
        className="acpmux-attachment acpmux-attachment-image acpmux-attachment-pending"
        aria-busy="true"
        aria-label={name}
      >
        <Spinner loading size={16} className="acpmux-attachment-spinner" />
        {remove}
      </div>
    );
  const length = video ? (formatDuration(video.durationMs / 1000) ?? "") : "";
  return (
    <div
      className={`acpmux-attachment acpmux-attachment-image acpmux-attachment-video${video ? "" : " acpmux-attachment-video-unread"}`}
      /* tooltip-allow: a video's poster shows no name */ title={title}
    >
      <button
        type="button"
        className="acpmux-attachment-open acpmux-attachment-video-open"
        aria-label={length ? t("composer.playVideo", { name, length }) : t("media.play")}
        onClick={onPlay}
      >
        {video && <img alt="" src={video.poster} width={video.width} height={video.height} />}
        <span className="ui-glass acpmux-attachment-video-play" aria-hidden="true">
          <PlayTriangle size={12} style={{ color: "inherit" }} />
        </span>
        {length && (
          <span className="acpmux-attachment-video-length" aria-hidden="true">
            {length}
          </span>
        )}
      </button>
      {remove}
    </div>
  );
}

/// Plays the attached video at `path` in the pane: `play` asks the host for its streamed URL
/// (`media.load`) and opens `viewer`, the large player, playing; a video the host will not grant
/// (a chat on another machine) plays in Quick Look as before.
export function useAttachedVideoPlayer(path: string | undefined, name: string) {
  const [src, setSrc] = useState<string>();
  const asked = useRef(0);
  const play = useCallback(() => {
    if (!path) return;
    const ask = ++asked.current;
    void loadPlayableMedia(path).then((url) => {
      if (ask !== asked.current) return;
      if (url) setSrc(url);
      else void callChipHost("video.quickLook", { src: path });
    });
  }, [path]);
  // The player is portaled over the pane, but React still bubbles its events to the chip's parents
  // (the strip's drag reorder, the prompt's editor): they stop at this hidden span.
  const viewer = src ? (
    <span
      hidden
      role="presentation"
      onPointerDown={stop}
      onMouseDown={stop}
      onClick={stop}
      onKeyDown={stop}
      onContextMenu={stop}
    >
      <VideoViewer
        src={src}
        name={name}
        autoPlay
        onError={() => {
          // The pane's player could not play what the host granted: Quick Look plays it, on the
          // same click, instead of the player closing with nothing shown (Leo, 2026-11-03).
          setSrc(undefined);
          if (path) void callChipHost("video.quickLook", { src: path });
        }}
        onClose={() => setSrc(undefined)}
      />
    </span>
  ) : null;
  return { play, viewer };
}

const stop = (event: { stopPropagation(): void }) => event.stopPropagation();
