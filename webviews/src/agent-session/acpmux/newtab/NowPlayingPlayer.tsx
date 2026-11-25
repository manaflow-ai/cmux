// The New Tab page's Now Playing player: the sidebar card's track under the create actions (Leo,
// from Austin's idea: a player you enjoy being in). Laid out like Apple's Now Playing widget and
// Control Center's media module: rounded artwork, the title in the primary text color, the artist
// in the secondary one, subtle level bars that sway while it plays, a thin progress line, and
// compact Previous, Play or Pause (the one filled control) and Next. The controls ask the host
// (`nowPlaying.command`), which runs them on whatever plays.
//
// Its right-click menu (Shift-F10 and the context-menu key too, ContextMenu.tsx): Play or Pause,
// Next, Previous, Open in the app that plays, then Hide Now Playing (`tabs.newTabNowPlaying` off,
// with an Undo in its place) and Now Playing Settings…. Items the source cannot do are disabled.
// The bars and the progress line hold still under prefers-reduced-motion (screen.css).
import { useState } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import { usePageNow } from "../../../ui/pageClock";
import { type NowPlayingTrack, progress, useNowPlaying } from "./nowPlaying";
import { useNt } from "./strings";
import { type NowPlayingCommand, nowPlayingMenuItems } from "./nowPlayingPlayerModel";
function Glyph({ name }: { name: "play" | "pause" | "previous" | "next" | "note" }) {
  const paths = {
    play: "M8 5.5v13a1 1 0 0 0 1.5.86l10.6-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5Z",
    pause: "M7 5h3.5v14H7zM13.5 5H17v14h-3.5z",
    previous: "M6 5h2v14H6zM19 5.8v12.4a.8.8 0 0 1-1.25.66L9.5 12.66a.8.8 0 0 1 0-1.32l8.25-6.2A.8.8 0 0 1 19 5.8Z",
    next: "M16 5h2v14h-2zM5 5.8v12.4a.8.8 0 0 0 1.25.66l8.25-6.2a.8.8 0 0 0 0-1.32L6.25 5.14A.8.8 0 0 0 5 5.8Z",
    note: "M18 3.5v11.25a3.25 3.25 0 1 1-1.75-2.88V7.4l-7.5 1.6v7.75a3.25 3.25 0 1 1-1.75-2.88V6.6a1 1 0 0 1 .79-.98l9-1.92A1 1 0 0 1 18 4.68Z",
  };
  return (
    <svg viewBox="0 0 24 24" width="100%" height="100%" aria-hidden="true" focusable="false">
      <path d={paths[name]} fill="currentColor" />
    </svg>
  );
}

/// The played share now, again each second while it plays, on the page's shared second clock
/// (no timer while the page is hidden or the track is paused).
function useProgress(track: NowPlayingTrack): number | null {
  const now = usePageNow(track.playing && track.duration !== undefined);
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
    <ContextMenu className="nt-player-host" items={nowPlayingMenuItems(track, nt, onCommand)}>
      <section
        className="nt-player"
        aria-label={nt("nowPlaying.label")}
        data-playing={track.playing ? "true" : "false"}
        data-artwork={track.artwork ? "true" : "false"}
      >
        <div className="nt-player-art" aria-hidden="true">
          {track.artwork ? (
            <img src={track.artwork} alt="" draggable={false} />
          ) : (
            <span className="nt-player-art-empty">
              <Glyph name="note" />
            </span>
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
              <div className="nt-player-played" style={{ transform: `scaleX(${played})` }} />
            </div>
          )}
          <div className="nt-player-controls">
            <button
              type="button"
              className="nt-player-button"
              data-command="previous"
              aria-label={labels.previous}
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
              onClick={() => onCommand("playPause")}
            >
              <Glyph name={track.playing ? "pause" : "play"} />
            </button>
            <button
              type="button"
              className="nt-player-button"
              data-command="next"
              aria-label={labels.next}
              disabled={!track.canNext}
              onClick={() => onCommand("next")}
            >
              <Glyph name="next" />
            </button>
          </div>
        </div>
      </section>
    </ContextMenu>
  );
}

/// The player while something plays and the host shows it; nothing otherwise, so the page keeps
/// no space for it. Hide Now Playing leaves a one-line note with Undo in its place until the page
/// goes; the next New Tab page draws nothing.
export function NowPlayingPlayer({ onCommand }: { onCommand?(command: NowPlayingCommand): void }) {
  const nt = useNt();
  const track = useNowPlaying();
  const [hidden, setHidden] = useState(false);
  if (!onCommand) return null;
  if (hidden)
    return (
      <output className="nt-player-note">
        <span className="nt-player-note-text">{nt("nowPlaying.hidden")}</span>
        <button
          type="button"
          className="nt-player-undo"
          onClick={() => {
            setHidden(false);
            onCommand("show");
          }}
        >
          {nt("nowPlaying.undo")}
        </button>
      </output>
    );
  if (!track) return null;
  return (
    <NowPlayingCard
      track={track}
      onCommand={(command) => {
        if (command === "hide") setHidden(true);
        onCommand(command);
      }}
    />
  );
}
