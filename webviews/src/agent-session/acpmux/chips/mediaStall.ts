// A player asked to play whose media never comes ends as a player that failed, never as a spinner
// with a pause button and 0:00 that turns forever (Leo, 2026-11-08: "the video previews maybe don't
// work ? they don't load."). An `error` event comes only when the load fails; a URL whose bytes never
// arrive (a host's answer that does not come, a stream that stops) fires none, so the player waits
// for its first frame a bounded time from the Play: each byte that arrives (`progress`) starts that
// time again, and its first frame (`loadeddata`, or playing) ends the wait. Past it, `onStall` falls
// back as the caller's `onError` does (the composer's chip plays it in Quick Look).
import { useEffect, useRef, type RefObject } from "react";

/// How long a player asked to play may go without a byte before its first frame (a test shortens it).
export const mediaStall = { ms: 10_000 };

/// HTMLMediaElement.HAVE_CURRENT_DATA: the first frame is there.
const HAVE_CURRENT_DATA = 2;

/// Waits, while `asked` (the person pressed Play), for `media`'s first frame; calls `onStall` when no
/// byte of it arrives for `mediaStall.ms`.
export function usePlaybackStall(media: RefObject<HTMLMediaElement | null>, asked: boolean, onStall: () => void): void {
  const stall = useRef(onStall);
  useEffect(() => {
    stall.current = onStall;
  }, [onStall]);
  useEffect(() => {
    const element = media.current;
    if (!asked || !element || element.readyState >= HAVE_CURRENT_DATA) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let ended = false;
    const done = () => {
      ended = true;
      clearTimeout(timer);
      timer = undefined;
    };
    const wait = () => {
      if (ended) return;
      clearTimeout(timer);
      // timeout: a load that fires no event has no other end
      timer = setTimeout(() => {
        const stalled = element.readyState < HAVE_CURRENT_DATA;
        done();
        if (stalled) stall.current();
      }, mediaStall.ms);
    };
    element.addEventListener("loadeddata", done);
    element.addEventListener("canplay", done);
    element.addEventListener("playing", done);
    // The load's own error goes to the player's onError; this wait ends with it.
    element.addEventListener("error", done);
    element.addEventListener("progress", wait);
    wait();
    return () => {
      done();
      element.removeEventListener("loadeddata", done);
      element.removeEventListener("canplay", done);
      element.removeEventListener("playing", done);
      element.removeEventListener("error", done);
      element.removeEventListener("progress", wait);
    };
  }, [asked, media]);
}
