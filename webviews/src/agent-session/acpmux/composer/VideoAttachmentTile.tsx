// An attached video's chip (Leo, 2026-10-25: "also why dont we have previews of videos we should"):
// its poster in the image chip's tile, a small glass play glyph in its middle and its length in a
// corner, like a reply's video thumbnail (chips/ReplyMedia.tsx). A click plays it in Quick Look.
// While the host reads it (composer/videoAttachments.ts) the tile spins, in the shape it will have;
// one the host could not read keeps that square with the play glyph and no poster, never a file
// chip's long strip (Leo, 2026-10-26: "not for screen recordings. Don't do it for screen
// recordings. We know it's a video. ... Just do the square. Why do we have these long-ass
// rectangles anyway?").
import type { ReactNode } from "react";
import { formatDuration } from "../chips/ReplyMedia";
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
