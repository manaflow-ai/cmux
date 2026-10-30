// An attached video's chip (Leo, 2026-10-25: "also why dont we have previews of videos we should"):
// its poster in the image chip's tile, a small glass play glyph in its middle and its length in a
// corner, like a reply's video thumbnail (chips/ReplyMedia.tsx). A click plays it in Quick Look.
// While the host reads it (composer/videoAttachments.ts) the tile spins, in the shape it will have.
import type { ReactNode } from "react";
import { formatDuration } from "../chips/ReplyMedia";
import { PlayTriangle, Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import type { VideoInfo } from "./videoAttachments";

export function VideoAttachmentTile({
  name,
  video,
  remove,
  onPlay,
}: {
  name: string;
  /// Unset while the host reads it.
  video: VideoInfo | undefined;
  remove: ReactNode;
  onPlay(): void;
}) {
  const t = useT();
  if (!video)
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
  const length = formatDuration(video.durationMs / 1000) ?? "";
  return (
    <div
      className="acpmux-attachment acpmux-attachment-image acpmux-attachment-video"
      /* tooltip-allow: a video's poster shows no name */ title={name}
    >
      <button
        type="button"
        className="acpmux-attachment-open acpmux-attachment-video-open"
        aria-label={t("composer.playVideo", { name, length })}
        onClick={onPlay}
      >
        <img alt="" src={video.poster} width={video.width} height={video.height} />
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
