import { useCallback, useRef, useState } from "react";
import { callChipHost } from "../chips/host";
import { VideoViewer } from "../chips/ReplyMedia";
import { loadPlayableMedia } from "../chips/replyMediaModel";

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
