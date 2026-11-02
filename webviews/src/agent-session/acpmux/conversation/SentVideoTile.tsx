// A video a prompt sent, in its bubble's row of images (Leo, 2026-10-25: "also why dont we have
// previews of videos we should"): its poster (the first frame the agent got, read from acpmux as a
// sent image is), a glass play glyph and its length, at a sent image's height and its own shape, as
// the composer's tile drew it (composer/VideoAttachmentTile.tsx). A click plays it in Quick Look
// (`video.quickLook`, which the host checks like any path).
import { useContext } from "react";
import { useT } from "../i18n";
import { callChipHost } from "../chips/host";
import { PlayTriangle } from "./icons";
import { useStableImage } from "./imageEntries";
import { TurnActionsContext } from "./turnActions";
import type { SentVideo } from "./sentVideos";

/// `width`: the tile's at a sent image's height (UserBubble.tsx `sentImageWidth`).
export function SentVideoTile({ video, width }: { video: SentVideo; width: number }) {
  const t = useT();
  return (
    <button
      type="button"
      className="cv-user__video"
      /* tooltip-allow: a video's poster shows no name */ title={video.name}
      aria-label={t("composer.playVideo", { name: video.name, length: video.length })}
      style={{ width }}
      onClick={() => void callChipHost("video.quickLook", { src: video.path })}
    >
      {video.poster ? (
        <Poster video={video} width={width} />
      ) : (
        <span className="cv-user__image-placeholder" aria-hidden="true" style={{ width, flexBasis: width }} />
      )}
      <span className="ui-glass cv-user__video-play" aria-hidden="true">
        <PlayTriangle size={16} style={{ color: "inherit" }} />
      </span>
      <span className="cv-user__video-length" aria-hidden="true">
        {video.length}
      </span>
    </button>
  );
}

/// The first frame: the pane's own bytes before acpmux's echo, else read by its id (imageEntries.ts).
function Poster({ video, width }: { video: SentVideo; width: number }) {
  const { promptImage } = useContext(TurnActionsContext);
  const image = video.poster!;
  const shown = useStableImage(image.src ? { src: image.src } : { id: image.id, read: promptImage }, video);
  if (shown.src === undefined)
    return <span className="cv-user__image-placeholder" aria-hidden="true" style={{ width, flexBasis: width }} />;
  return (
    <img
      className={shown.fresh ? "cv-user__image cv-enter" : "cv-user__image"}
      src={shown.src}
      alt=""
      decoding={shown.decoded ? "sync" : "async"}
      width={video.width}
      height={video.height}
      style={{ width }}
      onLoad={shown.onLoad}
    />
  );
}
