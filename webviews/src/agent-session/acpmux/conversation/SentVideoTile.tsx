// A video a prompt sent, in its bubble's row of images (Leo, 2026-10-25: "also why dont we have
// previews of videos we should"): its poster (the first frame the agent got, read from acpmux as a
// sent image is), a glass play glyph and its length, at a sent image's height and its own shape, as
// the composer's tile drew it (composer/VideoAttachmentTile.tsx). A click plays it in place (Leo,
// 2026-11-02: "this i can't play a video preview inside cmux next? i feel like i should be able
// to"): the tile becomes the reply's player (chips/ReplyMedia.tsx MediaPlayer), playing with sound and
// its controls (scrub, mute, pause), with Expand and Open in tab. A double-click opens it large over
// the pane (VideoViewer), as a sent image opens in its viewer. The host grants the file
// (`media.load`, checked like any path) as a URL its scheme handler serves in byte ranges, so a file
// of any size streams. Quick Look plays it when the host will not grant it, and when the pane's
// player cannot play what it granted (Leo, 2026-11-03: "i can neither preview a vid in place nor
// have it pop up anymore"): a click always plays it somewhere, never falls back to the tile silently.
import { useContext, useRef, useState } from "react";
import { useT } from "../i18n";
import { callChipHost } from "../chips/host";
import { loadPlayableMedia, MediaPlayer, VideoViewer } from "../chips/ReplyMedia";
import { PlayTriangle } from "./icons";
import { useStableImage } from "./imageEntries";
import { TurnActionsContext } from "./turnActions";
import type { SentVideo } from "./sentVideos";

/// Where a granted video plays: in place in the bubble, or large over the pane.
type Shown = { src: string; expanded: boolean };

/// `width` and `height`: the tile's, at a sent image's height (UserBubble.tsx `sentImageWidth`). The
/// poster fills it, cropped, loaded or still loading.
export function SentVideoTile({ video, width, height }: { video: SentVideo; width: number; height: number }) {
  const t = useT();
  const [shown, setShown] = useState<Shown>();
  const asked = useRef(0);
  const quickLook = () => void callChipHost("video.quickLook", { src: video.path });
  const open = (expanded: boolean) => {
    if (shown) {
      setShown({ ...shown, expanded });
      return;
    }
    const ask = ++asked.current;
    void loadPlayableMedia(video.path).then((url) => {
      if (ask !== asked.current) return;
      if (url) setShown((current) => ({ src: url, expanded: current?.expanded || expanded }));
      else quickLook();
    });
  };
  // The pane's player could not play the granted file: the tile comes back and Quick Look plays it,
  // on the same click (the host keeps the person's gesture until a granting call spends it).
  const failed = () => {
    asked.current++;
    setShown(undefined);
    quickLook();
  };
  if (shown && !shown.expanded)
    return (
      <span className="cv-user__video-player" onDoubleClick={() => open(true)}>
        <MediaPlayer
          src={shown.src}
          source={video.path}
          kind="video"
          name={video.name}
          path={video.path}
          autoPlay
          onError={failed}
        />
      </span>
    );
  return (
    <>
      <button
        type="button"
        className="cv-user__video"
        /* tooltip-allow: a video's poster shows no name */ title={video.name}
        aria-label={t("composer.playVideo", { name: video.name, length: video.length })}
        style={{ width }}
        onClick={() => open(false)}
        onDoubleClick={() => open(true)}
      >
        {video.poster ? (
          <Poster video={video} width={width} height={height} />
        ) : (
          <span className="cv-user__image-placeholder" aria-hidden="true" style={{ width, height, flexBasis: width }} />
        )}
        <span className="ui-glass cv-user__video-play" aria-hidden="true">
          <PlayTriangle size={16} style={{ color: "inherit" }} />
        </span>
        <span className="cv-user__video-length" aria-hidden="true">
          {video.length}
        </span>
      </button>
      {shown?.expanded && (
        <VideoViewer
          src={shown.src}
          name={video.name}
          autoPlay
          onError={failed}
          onClose={() => {
            asked.current++;
            setShown(undefined);
          }}
        />
      )}
    </>
  );
}

/// The first frame: the pane's own bytes before acpmux's echo, else read by its id (imageEntries.ts).
function Poster({ video, width, height }: { video: SentVideo; width: number; height: number }) {
  const { promptImage } = useContext(TurnActionsContext);
  const image = video.poster!;
  const shown = useStableImage(image.src ? { src: image.src } : { id: image.id, read: promptImage }, video);
  if (shown.src === undefined)
    return (
      <span className="cv-user__image-placeholder" aria-hidden="true" style={{ width, height, flexBasis: width }} />
    );
  return (
    <img
      className={shown.fresh ? "cv-user__image cv-enter" : "cv-user__image"}
      src={shown.src}
      alt=""
      decoding={shown.decoded ? "sync" : "async"}
      width={video.width}
      height={video.height}
      style={{ width, height }}
      onLoad={shown.onLoad}
    />
  );
}
