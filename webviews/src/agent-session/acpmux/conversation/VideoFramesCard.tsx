// The frames an agent looked at in a video (videoFrames.ts), under the tool row that read them: a
// filmstrip of the frames, each with its time, and the video's name and length above it (Leo,
// 2026-11-01: "i feel like cmux-next should give u better tools to deal with this kind of thing").
// A frame opens large in the pane's image viewer; the name plays the video in Quick Look, the same
// viewer an attached video's tile opens (`video.quickLook`, which the host checks like any path).
// Every frame draws in a box of the video's shape before it decodes, so the transcript never moves.
// `layout` keeps the gallery's alternatives (VideoFramesCard.gallery.tsx); the transcript draws `strip`.
import { createContext, useContext, type CSSProperties } from "react";
import { callChipHost } from "../chips/host";
import { formatDuration } from "../chips/ReplyMedia";
import { useT } from "../i18n";
import { ImageViewerContext } from "./imageViewerContext";
import { PlayTriangle } from "./icons";
import { useTranscriptReadOnly } from "./readOnly";
import { frameLabel, needsTenths, type VideoFrame, type VideoFrames } from "./videoFrames";

export type VideoFramesLayout = "strip" | "grid" | "poster";

/// The layout the transcript's cards take: `strip`, but for the gallery's comparison.
export const VideoFramesLayoutContext = createContext<VideoFramesLayout>("strip");

/// The shape a frame box takes: the video's, held between 9:16 and 21:9.
function aspect(video: VideoFrames): number {
  const ratio = video.width && video.height ? video.width / video.height : 16 / 9;
  return Math.min(21 / 9, Math.max(9 / 16, ratio));
}

export function VideoFramesCard({ video }: { video: VideoFrames }) {
  const t = useT();
  const layout = useContext(VideoFramesLayoutContext);
  const readOnly = useTranscriptReadOnly();
  const openImage = useContext(ImageViewerContext);
  const tenths = needsTenths(video.frames);
  const length = video.durationMs ? formatDuration(video.durationMs / 1000) : undefined;
  const name = video.name ?? "";
  const playable = Boolean(video.path) && !readOnly;
  const style = { "--cv-video-frame-aspect": String(aspect(video)) } as CSSProperties;
  const time = (frame: VideoFrame) => (frame.atMs === undefined ? undefined : frameLabel(frame.atMs, tenths));
  const alt = (frame: VideoFrame) => {
    const at = time(frame);
    return at && name ? t("media.videoFrameAt", { name, time: at }) : name;
  };
  const frameButton = (frame: VideoFrame, index: number, lead = false) => {
    const at = time(frame);
    const image = <img src={frame.src} alt={alt(frame)} loading="lazy" decoding="async" draggable={false} />;
    const badge = at && (
      <span className="cv-video-frames__time" aria-hidden="true">
        {at}
      </span>
    );
    const className = `cv-video-frames__frame${lead ? " is-lead" : ""}`;
    if (!openImage)
      return (
        <span key={index} className={className}>
          {image}
          {badge}
        </span>
      );
    return (
      <button
        key={index}
        type="button"

        className={className}
        data-open-image
        title={alt(frame) || t("image.view")}
        onClick={() => openImage(frame.src, alt(frame))}
      >
        {image}
        {badge}
      </button>
    );
  };
  const head = (
    <div className="cv-video-frames__head">
      {playable ? (
        <button
          type="button"
          className="cv-video-frames__name is-playable"
          title={video.path}
          aria-label={length ? t("composer.playVideo", { name, length }) : t("media.play")}
          onClick={() => void callChipHost("video.quickLook", { src: video.path! })}
        >
          <PlayTriangle size={10} className="cv-video-frames__play" />
          <span className="cv-video-frames__label">{name}</span>
        </button>
      ) : (
        name && (
          <span className="cv-video-frames__name" title={video.path}>
            <span className="cv-video-frames__label">{name}</span>
          </span>
        )
      )}
      {(length || (video.width && video.height)) && (
        <span className="cv-video-frames__meta">
          {length}
          {length && video.width && video.height ? " · " : ""}
          {video.width && video.height ? `${video.width}×${video.height}` : ""}
        </span>
      )}
    </div>
  );
  if (layout === "poster") {
    const [lead, ...rest] = video.frames;
    return (
      <div className="cv-video-frames is-poster" style={style}>
        <div className="cv-video-frames__poster">{lead && frameButton(lead, 0, true)}</div>
        {rest.length > 0 && (
          <div className="cv-video-frames__strip">{rest.map((frame, index) => frameButton(frame, index + 1))}</div>
        )}
        {head}
      </div>
    );
  }
  return (
    <div className={`cv-video-frames is-${layout}`} style={style}>
      {head}
      <div className={layout === "grid" ? "cv-video-frames__grid" : "cv-video-frames__strip"}>
        {video.frames.map((frame, index) => frameButton(frame, index))}
      </div>
    </div>
  );
}
