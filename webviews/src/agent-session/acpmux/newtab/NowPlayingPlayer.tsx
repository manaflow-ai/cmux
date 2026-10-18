// The New Tab page's Now Playing player: the sidebar card's track, large, under the create actions
// (Leo, from Austin's idea: a player you enjoy being in, like YouTube Music). Artwork, title and
// artist with level bars that sway while it plays, a thin progress line, and Previous, Play or
// Pause (the one filled control) and Next. The controls ask the host (`nowPlaying.command`), which
// runs them on whatever plays. The bars and the progress line hold still under
// prefers-reduced-motion (screen.css); nothing flashes.
import React, { useEffect, useState } from "react";
import { type NowPlayingTrack, progress, useNowPlaying } from "./nowPlaying";
import { useNt } from "./strings";

export type NowPlayingCommand = "playPause" | "previous" | "next";

function Glyph({ name }: { name: "play" | "pause" | "previous" | "next" }) {
  const paths = {
    play: "M8 5.5v13a1 1 0 0 0 1.5.86l10.6-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5Z",
    pause: "M7 5h3.5v14H7zM13.5 5H17v14h-3.5z",
    previous: "M6 5h2v14H6zM19 5.8v12.4a.8.8 0 0 1-1.25.66L9.5 12.66a.8.8 0 0 1 0-1.32l8.25-6.2A.8.8 0 0 1 19 5.8Z",
    next: "M16 5h2v14h-2zM5 5.8v12.4a.8.8 0 0 0 1.25.66l8.25-6.2a.8.8 0 0 0 0-1.32L6.25 5.14A.8.8 0 0 0 5 5.8Z",
  };
  return (
    <svg viewBox="0 0 24 24" width="100%" height="100%" aria-hidden="true" focusable="false">
      <path d={paths[name]} fill="currentColor" />
    </svg>
  );
}

/// The played share now, again each second while it plays (one timer, only while shown and playing).
function useProgress(track: NowPlayingTrack): number | null {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!track.playing || track.duration === undefined) return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [track.playing, track.duration, track.positionDate]);
  return progress(track, Math.max(now, track.positionDate));
}

export function NowPlayingCard({
  track,
  onCommand,
}: {
  track: NowPlayingTrack;
  onCommand(command: NowPlayingCommand): void;
}) {
  const nt = useNt();
  const played = useProgress(track);
  const { labels } = track;
  return (
    <section className="nt-player" aria-label={nt("nowPlaying.label")} data-playing={track.playing ? "true" : "false"}>
      <div className="nt-player-art" aria-hidden="true">
        {track.artwork ? (
          <img src={track.artwork} alt="" draggable={false} />
        ) : (
          <span className="nt-player-art-empty" />
        )}
      </div>
      <div className="nt-player-body">
        <div className="nt-player-head">
          <div className="nt-player-text">
            <div className="nt-player-title">{track.title}</div>
            {track.artist && <div className="nt-player-artist">{track.artist}</div>}
          </div>
          <span className="nt-player-levels" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
        </div>
        {played !== null && (
          <div className="nt-player-track" aria-hidden="true">
            <div className="nt-player-played" style={{ width: `${(played * 100).toFixed(2)}%` }} />
          </div>
        )}
        <div className="nt-player-controls">
          <button
            type="button"
            className="nt-player-button"
            data-command="previous"
            aria-label={labels.previous}
            title={labels.previous}
            disabled={!track.canPrevious}
            onClick={() => onCommand("previous")}
          >
            <Glyph name="previous" />
          </button>
          <button
            type="button"
            className="nt-player-button nt-player-play"
            data-command="playPause"
            aria-label={track.playing ? labels.pause : labels.play}
            title={track.playing ? labels.pause : labels.play}
            onClick={() => onCommand("playPause")}
          >
            <Glyph name={track.playing ? "pause" : "play"} />
          </button>
          <button
            type="button"
            className="nt-player-button"
            data-command="next"
            aria-label={labels.next}
            title={labels.next}
            disabled={!track.canNext}
            onClick={() => onCommand("next")}
          >
            <Glyph name="next" />
          </button>
        </div>
      </div>
    </section>
  );
}

/// The player while something plays and the host shows it; nothing otherwise.
export function NowPlayingPlayer({ onCommand }: { onCommand?(command: NowPlayingCommand): void }) {
  const track = useNowPlaying();
  if (!track || !onCommand) return null;
  return <NowPlayingCard track={track} onCommand={onCommand} />;
}
