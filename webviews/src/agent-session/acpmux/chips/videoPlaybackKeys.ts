import type { KeyboardEvent } from "react";
import { nextRate, playbackKey, steppedTime, type PlaybackKey } from "./videoPlaybackModel";

/// Applies a viewer key to `videos` (the first leads); true when it was the viewer's.
export function applyPlaybackKey(key: PlaybackKey, videos: HTMLVideoElement[]): boolean {
  const lead = videos[0];
  if (!lead) return false;
  switch (key.kind) {
    case "toggle":
      if (lead.paused) for (const video of videos) void video.play()?.catch(() => {});
      else for (const video of videos) video.pause();
      return true;
    case "step": {
      for (const video of videos) video.pause();
      const time = steppedTime(lead.currentTime, key.direction, lead.duration);
      for (const video of videos)
        video.currentTime = Math.min(time, Number.isFinite(video.duration) ? video.duration : time);
      return true;
    }
    case "rate": {
      const rate = nextRate(lead.playbackRate, key.direction);
      for (const video of videos) video.playbackRate = rate;
      return true;
    }
    case "loop": {
      const loop = !lead.loop;
      for (const video of videos) video.loop = loop;
      return true;
    }
  }
}

/// Viewer keys on `videos` from a key event, for a dialog's onKeyDown. A key typed into a control
/// that uses it (the scrub's arrows, a focused button's Space) stays the control's.
export function onPlaybackKeyDown(event: KeyboardEvent<HTMLElement>, videos: () => HTMLVideoElement[]) {
  const key = playbackKey(event);
  if (!key) return;
  const target = event.target as HTMLElement | null;
  if (key.kind === "toggle" && target?.closest("button, input, video")) return;
  if (applyPlaybackKey(key, videos())) {
    event.preventDefault();
    event.stopPropagation();
  }
}
