import { useCallback, useRef, useState } from "react";
import { tryChipHost } from "../chips/host";
import { VideoViewer } from "../chips/ReplyMedia";
import { loadPlayableMedia } from "../chips/replyMediaModel";

/// Plays the attached video at `path` in the pane: `play` asks the host for its streamed URL
/// (`media.load`) and opens `viewer`, the large player, playing. In a chat on another machine the
/// path is the chip's upload there, and the host streams it from that machine. A video the host
/// will not grant plays in Quick Look; when that is refused too, `unplayable` is set and the chip
/// says so (Leo, 2026-11-04: "i can neither preview a vid in place nor have it pop up anymore :("),
/// never a click that does nothing.
export function useAttachedVideoPlayer(path: string | undefined, name: string) {
  const [src, setSrc] = useState<string>();
  const [unplayable, setUnplayable] = useState(false);
  const asked = useRef(0);
  const quickLook = useCallback(
    (ask: number) => {
      if (!path) return;
      void tryChipHost("video.quickLook", { src: path }).then((played) => {
        if (ask === asked.current) setUnplayable(!played);
      });
    },
    [path],
  );
  const play = useCallback(() => {
    if (!path) return;
    const ask = ++asked.current;
    void loadPlayableMedia(path).then((url) => {
      if (ask !== asked.current) return;
      if (url) {
        setUnplayable(false);
        setSrc(url);
      } else quickLook(ask);
    });
  }, [path, quickLook]);
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
          quickLook(++asked.current);
        }}
        onClose={() => setSrc(undefined)}
      />
    </span>
  ) : null;
  return { play, viewer, unplayable };
}

const stop = (event: { stopPropagation(): void }) => event.stopPropagation();
