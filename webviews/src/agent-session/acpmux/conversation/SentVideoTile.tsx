// A video a prompt sent, in its bubble's row of images (Leo, 2026-10-25: "also why dont we have
// previews of videos we should"): its poster (the first frame the agent got, read from acpmux as a
// sent image is), a glass play glyph and its length, at a sent image's height and its own shape, as
// the composer's tile drew it (composer/VideoAttachmentTile.tsx). A click plays it in place (Leo,
// 2026-11-02: "this i can't play a video preview inside cmux next? i feel like i should be able
// to"): the tile becomes the reply's player (chips/ReplyMedia.tsx MediaPlayer), playing with sound and
// its controls (scrub, mute, pause), with Expand and Open in tab. The host grants the file
// (`media.load`, checked like any path) as a URL its scheme handler serves in byte ranges, so a file
// of any size streams. Quick Look plays it only when the host will not grant it.
import { useContext, useRef, useState } from "react";
import { useT } from "../i18n";
import { callChipHost } from "../chips/host";
import { loadPlayableMedia, MediaPlayer } from "../chips/ReplyMedia";
import { PlayTriangle } from "./icons";
import { useStableImage } from "./imageEntries";
import { TurnActionsContext } from "./turnActions";
import type { SentVideo } from "./sentVideos";

/// `width`: the tile's at a sent image's height (UserBubble.tsx `sentImageWidth`).
export function SentVideoTile({ video, width }: { video: SentVideo; width: number }) {
  const t = useT();
  const [src, setSrc] = useState<string>();
  const asked = useRef(0);
  const play = () => {
    const ask = ++asked.current;
    void loadPlayableMedia(video.path).then((url) => {
      if (ask !== asked.current) return;
      if (url) setSrc(url);
      else void callChipHost("video.quickLook", { src: video.path });
    });
  };
  if (src)
    return (
      <span className="cv-user__video-player">
        <MediaPlayer
          src={src}
          source={video.path}
          kind="video"
          name={video.name}
          path={video.path}
          autoPlay
          onError={() => setSrc(undefined)}
        />
      </span>
    );
  return (
    <button
      type="button"
      className="cv-user__video"
      /* tooltip-allow: a video's poster shows no name */ title={video.name}
      aria-label={t("composer.playVideo", { name: video.name, length: video.length })}
      style={{ width }}
      onClick={play}
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
