// The video viewer's own controls and the before/after compare viewer (Leo, 2026-11-22: "is there a
// way we can just watch the .mp4s in the app? i want that. in-app video player."). The large player
// (ReplyMedia.tsx VideoViewer) keeps the native bar for play, scrub and volume and adds this row:
// speed (0.5x, 1x, 2x), a frame step either way and loop. The compare viewer plays two clips side by
// side (or one above the other) on one clock: one play, one scrub, one speed, one step, and the
// second clip follows the first frame for frame. Rules live in videoPlaybackModel.ts.
import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from "react";
import { Dialog } from "../../../ui/Dialog";
import { keyedIconProps } from "../../../ui/DialogButton";
import { useScrimClose } from "../../../ui/scrimClose";
import { belowTabRowStyle, useTabRow } from "../header/tabRow";
import { useT } from "../i18n";
import { Close, PlayTriangle } from "../conversation/icons";
import { loadPlayableMedia } from "./replyMediaModel";
import {
  PLAYBACK_RATES,
  clockTime,
  followerSeek,
  nextRate,
  pairCaptions,
  playbackKey,
  steppedTime,
  type PlaybackKey,
} from "./videoPlaybackModel";

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

/// What the bar shows of the lead clip, read when it changes. A snapshot in state, never read off the
/// element while rendering: React Compiler memoizes such reads on the element, which does not change.
type VideoSnapshot = { present: boolean; rate: number; loop: boolean; paused: boolean; time: number; duration: number };

const NO_VIDEO: VideoSnapshot = { present: false, rate: 1, loop: false, paused: true, time: 0, duration: 0 };

function snapshotOf(video: HTMLVideoElement | undefined): VideoSnapshot {
  if (!video) return NO_VIDEO;
  return {
    present: true,
    rate: video.playbackRate,
    loop: video.loop,
    paused: video.paused,
    time: video.currentTime,
    duration: Number.isFinite(video.duration) ? video.duration : 0,
  };
}

/// The lead of `videos`, followed through its rate, loop, play state and position.
function useVideoState(videos: () => HTMLVideoElement[]): VideoSnapshot {
  const [snapshot, setSnapshot] = useState<VideoSnapshot>(NO_VIDEO);
  useEffect(() => {
    const list = videos();
    const update = () => setSnapshot(snapshotOf(list[0]));
    const events = ["ratechange", "play", "pause", "timeupdate", "seeked", "loadedmetadata", "durationchange"];
    for (const video of list) for (const name of events) video.addEventListener(name, update);
    // `loop` is an attribute, not an event: watch it so the toggle shows what the element does.
    const observer = typeof MutationObserver === "undefined" ? undefined : new MutationObserver(update);
    for (const video of list) observer?.observe(video, { attributes: true, attributeFilter: ["loop"] });
    update();
    return () => {
      for (const video of list) for (const name of events) video.removeEventListener(name, update);
      observer?.disconnect();
    };
  }, [videos]);
  return snapshot;
}

/// Speed, frame step and loop for `videos` (the first leads). `transport` adds play, a scrub bar
/// and the clock, for the compare viewer, whose clips have no native bar. `videos` changes identity
/// when its elements do.
export function PlaybackBar({ videos, transport = false }: { videos: () => HTMLVideoElement[]; transport?: boolean }) {
  const t = useT();
  const state = useVideoState(videos);
  const lead = state.present;
  const playing = lead && !state.paused;
  const apply = (key: PlaybackKey) => applyPlaybackKey(key, videos());
  const setRate = (value: number) => {
    for (const video of videos()) video.playbackRate = value;
  };
  return (
    <div className="cv-playback" role="toolbar" aria-label={t("media.player")}>
      {transport && (
        <>
          <button
            type="button"
            className="cv-playback__button cv-playback__play"
            aria-label={playing ? t("media.pause") : t("media.play")}
            title={playing ? t("media.pause") : t("media.play")}
            disabled={!lead}
            onClick={() => apply({ kind: "toggle" })}
          >
            {playing ? <PauseBars /> : <PlayTriangle size={14} style={{ color: "inherit" }} />}
          </button>
          <input
            type="range"
            className="cv-playback__scrub"
            aria-label={t("media.position")}
            min={0}
            max={state.duration || 1}
            step="any"
            value={state.time}
            disabled={!state.duration}
            onChange={(event) => {
              const time = Number(event.currentTarget.value);
              for (const video of videos())
                video.currentTime = Math.min(time, Number.isFinite(video.duration) ? video.duration : time);
            }}
          />
          <span className="cv-playback__clock" aria-hidden="true">
            {clockTime(state.time)} / {clockTime(state.duration)}
          </span>
        </>
      )}
      <fieldset className="cv-playback__group" aria-label={t("media.speed")}>
        {PLAYBACK_RATES.map((value) => (
          <button
            key={value}
            type="button"
            className="cv-playback__button cv-playback__rate"
            aria-pressed={Math.abs(state.rate - value) < 1e-6}
            disabled={!lead}
            onClick={() => setRate(value)}
          >
            {value}×
          </button>
        ))}
      </fieldset>
      <fieldset className="cv-playback__group">
        <button
          type="button"
          className="cv-playback__button"
          aria-label={t("media.stepBack")}
          title={`${t("media.stepBack")} (,)`}
          disabled={!lead}
          onClick={() => apply({ kind: "step", direction: -1 })}
        >
          <StepGlyph direction={-1} />
        </button>
        <button
          type="button"
          className="cv-playback__button"
          aria-label={t("media.stepForward")}
          title={`${t("media.stepForward")} (.)`}
          disabled={!lead}
          onClick={() => apply({ kind: "step", direction: 1 })}
        >
          <StepGlyph direction={1} />
        </button>
      </fieldset>
      <button
        type="button"
        className="cv-playback__button cv-playback__loop"
        aria-pressed={state.loop}
        aria-label={t("media.loop")}
        title={`${t("media.loop")} (L)`}
        disabled={!lead}
        onClick={() => apply({ kind: "loop" })}
      >
        <LoopGlyph />
      </button>
    </div>
  );
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

/// Keeps `follower` on `lead`'s frame and play state while both are mounted.
function useFollow(a: HTMLVideoElement | null, b: HTMLVideoElement | null) {
  useEffect(() => {
    if (!a || !b) return;
    const sync = () => {
      const seek = followerSeek(a.currentTime, b.currentTime, b.duration);
      if (seek !== undefined) b.currentTime = seek;
    };
    const play = () => {
      sync();
      void b.play()?.catch(() => {});
    };
    const pause = () => {
      b.pause();
      sync();
    };
    const rate = () => {
      b.playbackRate = a.playbackRate;
    };
    a.addEventListener("play", play);
    a.addEventListener("pause", pause);
    a.addEventListener("seeked", sync);
    a.addEventListener("timeupdate", sync);
    a.addEventListener("ratechange", rate);
    return () => {
      a.removeEventListener("play", play);
      a.removeEventListener("pause", pause);
      a.removeEventListener("seeked", sync);
      a.removeEventListener("timeupdate", sync);
      a.removeEventListener("ratechange", rate);
    };
  }, [a, b]);
}

export type CompareItem = { src: string; alt: string; label?: string };

/// Two clips over the pane, side by side or stacked, on one clock. Each source is loaded through the
/// host (`media.load`), as its inline player is; a clip the host will not play says so in its place.
export function CompareViewer({ items, onClose }: { items: [CompareItem, CompareItem]; onClose(): void }) {
  const t = useT();
  const close = useRef<HTMLButtonElement>(null);
  const below = belowTabRowStyle(useTabRow());
  const scrim = useScrimClose(onClose);
  const [sources, setSources] = useState<Array<string | null | undefined>>([undefined, undefined]);
  const [layout, setLayout] = useState<"row" | "stack">("row");
  // The two clips' elements, as state: the bar and the follow effect re-read them when one mounts.
  // (A stable callback reading refs would be memoized once by React Compiler, before either mounts.)
  const [leadElement, setLead] = useState<HTMLVideoElement | null>(null);
  const [followerElement, setFollower] = useState<HTMLVideoElement | null>(null);
  useEffect(() => {
    let live = true;
    // One after the other: a web clip under `images.remote = click` spends the click that opened this
    // viewer on its fetch, and the second may find the first's grant.
    void (async () => {
      for (const [index, item] of items.entries()) {
        const url = await loadPlayableMedia(item.src);
        if (!live) return;
        setSources((current) => current.map((value, at) => (at === index ? (url ?? null) : value)));
      }
    })();
    return () => {
      live = false;
    };
  }, [items]);
  useFollow(leadElement, followerElement);
  const videos = useCallback(
    () => [leadElement, followerElement].filter((v): v is HTMLVideoElement => Boolean(v)),
    [leadElement, followerElement],
  );
  const captions = pairCaptions(items, { before: t("media.before"), after: t("media.after") });
  const title = `${captions[0]} · ${captions[1]}`;
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={title}
      className="acpmux-image-viewer cv-compare"
      backdropClassName="acpmux-image-viewer-backdrop"
      style={below}
      initialFocus={close}
      onKeyDown={(event) => onPlaybackKeyDown(event, videos)}
    >
      <div className="acpmux-image-viewer-body">
        <div className="acpmux-image-viewer-bar">
          <span className="acpmux-image-viewer-title">{title}</span>
          <fieldset className="cv-playback__group">
            <button
              type="button"
              className="cv-playback__button"
              aria-pressed={layout === "row"}
              onClick={() => setLayout("row")}
            >
              {t("media.sideBySide")}
            </button>
            <button
              type="button"
              className="cv-playback__button"
              aria-pressed={layout === "stack"}
              onClick={() => setLayout("stack")}
            >
              {t("media.stacked")}
            </button>
          </fieldset>
          <button
            type="button"
            className="acpmux-image-viewer-action"
            ref={close}
            {...keyedIconProps(t("image.close"), "escape")}
            onClick={onClose}
          >
            <Close />
          </button>
        </div>
        {/* oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions */}
        <div className={`cv-compare__stage is-${layout}`} {...scrim.props}>
          {items.map((item, index) => {
            const src = sources[index];
            return (
              <figure key={index} className="cv-compare__clip">
                <span className="cv-compare__frame">
                  {src ? (
                    // oxlint-disable-next-line jsx-a11y/media-has-caption -- an agent's recording has no captions
                    <video
                      ref={index === 0 ? setLead : setFollower}
                      src={src}
                      playsInline
                      preload="auto"
                      muted={index === 1}
                      aria-label={captions[index]}
                      onLoadedMetadata={(event) => {
                        const element = event.currentTarget;
                        // Its first frame, as the inline poster shows it.
                        if (element.paused && element.currentTime === 0 && element.duration > 0.2)
                          element.currentTime = 0.1;
                      }}
                    />
                  ) : (
                    <span className="cv-compare__note">{src === null ? t("image.unavailable") : ""}</span>
                  )}
                </span>
                <figcaption className="cv-compare__caption">{captions[index]}</figcaption>
              </figure>
            );
          })}
        </div>
        <div className="cv-compare__controls">
          <PlaybackBar videos={videos} transport />
        </div>
      </div>
    </Dialog>
  );
}

function PauseBars() {
  return (
    <svg width={14} height={14} viewBox="0 0 14 14" aria-hidden="true">
      <rect x={3} y={2} width={3} height={10} rx={1} fill="currentColor" />
      <rect x={8} y={2} width={3} height={10} rx={1} fill="currentColor" />
    </svg>
  );
}

function StepGlyph({ direction }: { direction: -1 | 1 }) {
  return (
    <svg
      width={14}
      height={14}
      viewBox="0 0 14 14"
      aria-hidden="true"
      style={direction < 0 ? { transform: "scaleX(-1)" } : undefined}
    >
      <path d="M3 2.5v9l6-4.5z" fill="currentColor" />
      <rect x={10} y={2.5} width={1.6} height={9} rx={0.8} fill="currentColor" />
    </svg>
  );
}

function LoopGlyph() {
  return (
    <svg
      width={14}
      height={14}
      viewBox="0 0 14 14"
      aria-hidden="true"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.4}
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M2.5 7a3.5 3.5 0 0 1 3.5-3.5h5" />
      <path d="M9.5 1.8l1.7 1.7-1.7 1.7" />
      <path d="M11.5 7a3.5 3.5 0 0 1-3.5 3.5H3" />
      <path d="M4.5 12.2L2.8 10.5l1.7-1.7" />
    </svg>
  );
}
