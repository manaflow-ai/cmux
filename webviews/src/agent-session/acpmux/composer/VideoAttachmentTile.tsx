// An attached video's chip (Leo, 2026-10-25: "also why dont we have previews of videos we should"):
// its poster in the image chip's tile, a small glass play glyph in its middle and its length in a
// corner, like a reply's video thumbnail (chips/ReplyMedia.tsx). A click plays it in the pane
// (Leo, 2026-11-02: "this i can't play a video preview inside cmux next? i feel like i should be able
// to"): the tile is too small for a player's controls, so the player opens large over the pane
// (chips/ReplyMedia.tsx VideoViewer), playing, with scrub, mute and pause; the host serves the file in
// byte ranges, so any size streams. Quick Look plays it only when the host will not grant it.
// Its box is its shape from the paste on (composer/videoShape.ts), with its poster or without: while
// the host reads it (composer/videoAttachments.ts), and when it could not, the tile is that box with
// the play glyph on its neutral backing, never a spinner of another size and never a file chip's long
// strip (Leo, 2026-10-26: "not for screen recordings. Don't do it for screen recordings. We know it's
// a video. ... Just do the square. Why do we have these long-ass rectangles anyway?"). The chip is
// ready the moment it is there: it goes as its path, and the poster fills its box when the host has
// read it (Leo, 2026-11-10: "it's 99% of the time fine for it to just to be a path and stuff, so idk
// why it's so slow"). One nothing can play (`unplayable`: the host and Quick Look both refused it)
// says so in its tile instead of its play glyph (Leo, 2026-11-04: "i can neither preview a vid in
// place nor have it pop up anymore :(").
import { type ReactNode } from "react";

import { formatDuration } from "../chips/replyMediaModel";
import { PlayTriangle } from "../conversation/icons";
import { useT } from "../i18n";
import type { VideoInfo } from "./videoAttachments";
import { videoShapeStyle } from "./videoShape";

export function VideoAttachmentTile({
  name,
  title = name,
  video,
  shape,
  remove,
  onPlay,
  unplayable = false,
}: {
  name: string;
  /// The poster's tooltip: its name, with the line naming where it came from (SourceBadge.tsx).
  title?: string;
  /// Unset while the host reads it, or when it could not.
  video: VideoInfo | undefined;
  /// Its box's width over its height (videoShape.ts chipVideoRatio), the same with or without its poster.
  shape: number;
  remove: ReactNode;
  onPlay(): void;
  /// Nothing could play it: the tile says so.
  unplayable?: boolean;
}) {
  const t = useT();
  const length = video ? (formatDuration(video.durationMs / 1000) ?? "") : "";
  return (
    <div
      className={`acpmux-attachment acpmux-attachment-image acpmux-attachment-video${video ? "" : " acpmux-attachment-video-unread"}`}
      data-video-shape=""
      style={videoShapeStyle(shape)}
      /* tooltip-allow: a video's poster shows no name */ title={title}
    >
      <button
        type="button"
        className="acpmux-attachment-open acpmux-attachment-video-open"
        aria-label={length ? t("composer.playVideo", { name, length }) : t("media.play")}
        onClick={onPlay}
      >
        {video && <img alt="" src={video.poster} />}
        {unplayable ? (
          <output className="acpmux-attachment-video-unplayable">{t("media.cantPlayHere")}</output>
        ) : (
          <span className="ui-glass acpmux-attachment-video-play" aria-hidden="true">
            <PlayTriangle size={12} style={{ color: "inherit" }} />
          </span>
        )}
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
