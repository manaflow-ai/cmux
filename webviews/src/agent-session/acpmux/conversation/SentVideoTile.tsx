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
// A chat on another machine streams it from that machine (the host reads its ranges there). When
// nothing can play it (that machine refuses it, an older daemon, Quick Look refuses too), the tile
// says so (Leo, 2026-11-04: "i can neither preview a vid in place nor have it pop up anymore :("):
// a click never does nothing. A video sent without frames (sentVideos.ts) has no poster or length in
// the row: its tile reads them from the file (`video.info`, as the composer's chip does), at the size
// the row gave it, so nothing moves when they land; where the host cannot read it, the tile stays the
// square with its play glyph (Leo, 2026-11-06: "how come this didn't give a preview and only has
// file name?").
import { useContext, useEffect, useMemo, useRef, useState } from "react";
import { useT } from "../i18n";
import { callChipHost, tryChipHost } from "../chips/host";
import { lengthOf } from "../composer/videoPrompt";
import { parseVideoInfo, type VideoInfo } from "../composer/videoAttachments";
import { MediaPlayer, VideoViewer } from "../chips/ReplyMedia";
import { loadPlayableMedia } from "../chips/replyMediaModel";
import { PlayTriangle } from "./icons";
import { useStableImage } from "./imageEntries";
import { TurnActionsContext } from "./turnActions";
import type { SentVideo } from "./sentVideos";
import { AttachmentPreviewBoundary } from "../composer/AttachmentPreviewBoundary";
import { FileAttachment } from "../FileAttachment";

/// Where a granted video plays: in place in the bubble, or large over the pane.
type Shown = { src: string; expanded: boolean };

/// `width` and `height`: the tile's, at a sent image's height (UserBubble.tsx `sentImageWidth`). The
/// poster fills it, cropped, loaded or still loading.
type SentVideoTileProps = { video: SentVideo; width: number; height: number };

/// A sent video's tile. One whose preview throws while it draws is the video's file chip instead
/// (composer/AttachmentPreviewBoundary.tsx): the message and the pane stay.
export function SentVideoTile(props: SentVideoTileProps) {
  return (
    <AttachmentPreviewBoundary
      attachment={props.video}
      fallback={
        <span className="cv-sent-video-failed" data-preview-failed="true">
          <FileAttachment file={{ name: props.video.name, path: props.video.path }} />
        </span>
      }
    >
      <SentVideoTilePreview {...props} />
    </AttachmentPreviewBoundary>
  );
}

function SentVideoTilePreview({ video: sent, width, height }: SentVideoTileProps) {
  const t = useT();
  const video = useReadVideo(sent);
  const [shown, setShown] = useState<Shown>();
  /// Nothing could play it: the pane's player was refused it and Quick Look too.
  const [unplayable, setUnplayable] = useState(false);
  const asked = useRef(0);
  const quickLook = (ask: number) =>
    void tryChipHost("video.quickLook", { src: video.path }).then((played) => {
      if (ask === asked.current) setUnplayable(!played);
    });
  const open = (expanded: boolean) => {
    if (shown) {
      setShown({ ...shown, expanded });
      return;
    }
    const ask = ++asked.current;
    void loadPlayableMedia(video.path).then((url) => {
      if (ask !== asked.current) return;
      if (url) {
        setUnplayable(false);
        setShown((current) => ({ src: url, expanded: current?.expanded || expanded }));
      } else quickLook(ask);
    });
  };
  // The pane's player could not play the granted file: the tile comes back and Quick Look plays it,
  // on the same click (the host keeps the person's gesture until a granting call spends it).
  const failed = () => {
    const ask = ++asked.current;
    setShown(undefined);
    quickLook(ask);
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
        // A send from the latest row lands its chip's copy here (sendMorph.ts).
        data-send-key={`path:${video.path}`}
        /* tooltip-allow: a video's poster shows no name */ title={video.name}
        aria-label={
          video.length ? t("composer.playVideo", { name: video.name, length: video.length }) : t("media.play")
        }
        style={{ width }}
        onClick={() => open(false)}
        onDoubleClick={() => open(true)}
      >
        {video.poster ? (
          <Poster video={video} width={width} height={height} />
        ) : (
          <span className="cv-user__image-placeholder" aria-hidden="true" style={{ width, height, flexBasis: width }} />
        )}
        {unplayable ? (
          <output className="cv-user__video-unplayable">{t("media.cantPlayHere")}</output>
        ) : (
          <span className="ui-glass cv-user__video-play" aria-hidden="true">
            <PlayTriangle size={16} style={{ color: "inherit" }} />
          </span>
        )}
        {video.length && (
          <span className="cv-user__video-length" aria-hidden="true">
            {video.length}
          </span>
        )}
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

/// The host's reads of videos sent without frames, by path: each file read once per page, the most
/// recent READS_KEPT kept (a poster is a JPEG of at most 320 px).
const reads = new Map<string, Promise<VideoInfo | undefined>>();
const READS_KEPT = 64;

function readVideo(path: string): Promise<VideoInfo | undefined> {
  let read = reads.get(path);
  if (!read) {
    // A refusal is not kept: a host not ready yet (a reload, a reconnect) is asked again by the next tile.
    read = callChipHost("video.info", { src: path }).then(parseVideoInfo, () => {
      reads.delete(path);
      return undefined;
    });
    reads.set(path, read);
    if (reads.size > READS_KEPT) reads.delete(reads.keys().next().value!);
  }
  return read;
}

/// `video`, with the poster and length the host reads from its file when the row has no poster.
function useReadVideo(video: SentVideo): SentVideo {
  const [info, setInfo] = useState<{ path: string; info: VideoInfo }>();
  const needs = !video.poster;
  useEffect(() => {
    if (!needs) return;
    let live = true;
    void readVideo(video.path).then((read) => {
      if (live && read) setInfo({ path: video.path, info: read });
    });
    return () => {
      live = false;
    };
  }, [needs, video.path]);
  const read = needs && info?.path === video.path ? info.info : undefined;
  return useMemo(
    () =>
      read
        ? {
            ...video,
            length: video.length ?? lengthOf(read.durationMs),
            poster: { id: `${video.path}:poster`, mimeType: "image/jpeg", src: read.poster },
          }
        : video,
    [video, read],
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
