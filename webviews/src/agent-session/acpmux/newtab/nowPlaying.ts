// What plays, as the host pushes it for the New Tab page's player (`nowPlaying`, CmuxNextAgentPane
// AgentPaneNowPlaying): the sidebar card's track (cmux's player, a browser tab, Spotify, Music), or
// null while nothing plays or the player is hidden (`tabs.newTabNowPlaying`, off by default and
// apart from the sidebar card's `sidebar.nowPlaying.enabled`). A module store like
// recentlyClosed.ts, so a push that arrives before the screen mounts is kept.
import { useSyncExternalStore } from "react";

export type NowPlayingTrack = {
  title: string;
  artist: string;
  /// A `data:image/png` URL, the only images a cmux page may draw.
  artwork?: string;
  playing: boolean;
  /// Seconds in at `positionDate` (ms since 1970); absent for a live stream.
  position?: number;
  duration?: number;
  rate: number;
  positionDate: number;
  canPrevious: boolean;
  canNext: boolean;
  /// The app that plays (Spotify, Music), for the menu's Open in; absent for cmux's own player and tabs.
  source?: string;
  labels: { play: string; pause: string; previous: string; next: string };
};

let track: NowPlayingTrack | null = null;
const listeners = new Set<() => void>();

function finite(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function text(value: unknown, fallback: string): string {
  return typeof value === "string" && value ? value : fallback;
}

/// Replaces the track from a host push; anything malformed clears it.
export function setNowPlaying(value: unknown): void {
  const raw = value as Partial<NowPlayingTrack> | null;
  if (!raw || typeof raw !== "object" || typeof raw.title !== "string" || !raw.title) {
    track = null;
  } else {
    const labels = (raw.labels ?? {}) as Partial<NowPlayingTrack["labels"]>;
    const position = finite(raw.position);
    const duration = finite(raw.duration);
    track = {
      title: raw.title,
      artist: typeof raw.artist === "string" ? raw.artist : "",
      playing: raw.playing === true,
      rate: finite(raw.rate) ?? 1,
      positionDate: finite(raw.positionDate) ?? Date.now(),
      canPrevious: raw.canPrevious === true,
      canNext: raw.canNext === true,
      labels: {
        play: text(labels.play, "Play"),
        pause: text(labels.pause, "Pause"),
        previous: text(labels.previous, "Previous"),
        next: text(labels.next, "Next"),
      },
      ...(typeof raw.artwork === "string" && raw.artwork.startsWith("data:image/") ? { artwork: raw.artwork } : {}),
      ...(typeof raw.source === "string" && raw.source.trim() ? { source: raw.source.trim().slice(0, 64) } : {}),
      ...(position !== undefined ? { position } : {}),
      ...(duration !== undefined && duration > 0 ? { duration } : {}),
    };
  }
  for (const listener of listeners) listener();
}

export function nowPlaying(): NowPlayingTrack | null {
  return track;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useNowPlaying(): NowPlayingTrack | null {
  return useSyncExternalStore(subscribe, nowPlaying, nowPlaying);
}

/// The share of the track played at `now` (ms), 0 to 1; null without a known length.
export function progress(track: NowPlayingTrack, now: number): number | null {
  if (track.position === undefined || track.duration === undefined) return null;
  const moved = track.playing ? (Math.max(0, now - track.positionDate) / 1000) * track.rate : 0;
  return Math.min(1, Math.max(0, (track.position + moved) / track.duration));
}
