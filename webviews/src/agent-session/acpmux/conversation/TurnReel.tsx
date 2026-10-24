// A turn's reel: the frames a browser or computer-use run left, as one stage and a filmstrip under
// it (hq#3727, gallery-only for now). The stage shows the selected step with where it clicked; a
// pointer over the strip previews a step without choosing it, the arrow keys step through, a click
// on the stage opens the frame in the image viewer, and a recording plays only when asked.
import { type KeyboardEvent, useContext, useState } from "react";
import { useT } from "../i18n";
import { clockLabel } from "../replay/timeline";
import { PlayTriangle } from "./icons";
import { ImageViewerContext } from "./imageViewerContext";
import "./TurnReel.css";

/** One step of the run: its frame in source pixels, and where it clicked (0…1 of the frame). */
export type ReelFrame = {
  src: string;
  width: number;
  height: number;
  /** What the step did, as the tool call names it ("Click Sign in"). */
  label: string;
  /** Milliseconds since the turn started. */
  at: number;
  ok?: boolean;
  click?: { x: number; y: number };
};

/** How a step's click shows on its frame. `ripple` grows and fades once when the step shows. */
export type ReelMark = "ring" | "crosshair" | "ripple";

export type TurnReelProps = {
  frames: ReelFrame[];
  /** A recording of the run; it loads only when Play is pressed. */
  video?: string;
  mark?: ReelMark;
  /** The step shown first (the last one by default: where the run ended). */
  initial?: number;
  /** A named treatment, as `data-look` on the reel, for stylesheets that restyle the stage, strip
   *  and step change (gallery comparisons); absent draws the default look. */
  look?: string;
};

/// The stage's shape is the first frame's, known before any image loads, so nothing moves.
const STAGE_FALLBACK = 16 / 10;

/// Where `frame` draws inside a stage of `stage` aspect (object-fit: contain), in percent.
export function fittedBox(frame: { width: number; height: number }, stage: number) {
  const aspect = frame.width > 0 && frame.height > 0 ? frame.width / frame.height : stage;
  if (aspect >= stage) {
    const height = (stage / aspect) * 100;
    return { left: 0, top: (100 - height) / 2, width: 100, height };
  }
  const width = (aspect / stage) * 100;
  return { left: (100 - width) / 2, top: 0, width, height: 100 };
}

export function TurnReel({ frames, video, mark = "ring", initial, look }: TurnReelProps) {
  const t = useT();
  const openImage = useContext(ImageViewerContext);
  const last = frames.length - 1;
  const [selected, setSelected] = useState(() => Math.min(Math.max(initial ?? last, 0), last));
  const [hovered, setHovered] = useState<number | undefined>(undefined);
  const [playing, setPlaying] = useState(false);
  if (frames.length === 0) return null;
  const shown = hovered ?? selected;
  const frame = frames[shown]!;
  const first = frames[0]!;
  const stage = first.width > 0 && first.height > 0 ? first.width / first.height : STAGE_FALLBACK;
  const box = fittedBox(frame, stage);

  const step = (to: number) => {
    setHovered(undefined);
    setSelected(Math.min(Math.max(to, 0), last));
  };
  const onKeyDown = (event: KeyboardEvent) => {
    const to =
      event.key === "ArrowLeft"
        ? selected - 1
        : event.key === "ArrowRight"
          ? selected + 1
          : event.key === "Home"
            ? 0
            : event.key === "End"
              ? last
              : undefined;
    if (to === undefined) return;
    event.preventDefault();
    step(to);
    // Keep the chosen step's thumbnail in view and focused (roving tabindex).
    const strip = event.currentTarget as HTMLElement;
    const button = strip.querySelectorAll<HTMLButtonElement>(".cv-reel__thumb")[Math.min(Math.max(to, 0), last)];
    button?.focus();
    button?.scrollIntoView({ block: "nearest", inline: "nearest" });
  };

  const picture = (
    // Keyed by step: the shared enter fade (`cv-img--enter`) runs when the step changes.
    <img key={shown} className="cv-reel__img cv-img--enter" src={frame.src} alt={frame.label} decoding="async" />
  );
  const caption = [frame.label, clockLabel(frame.at), frame.ok === false ? t("tools.failed") : undefined]
    .filter(Boolean)
    .join(" · ");

  return (
    <figure className="cv-reel" data-mark={mark} data-look={look}>
      <div className="cv-reel__stage" style={{ aspectRatio: String(stage) }}>
        {playing && video ? (
          // oxlint-disable-next-line jsx-a11y/media-has-caption -- an agent's recording has no captions
          <video className="cv-reel__video" src={video} aria-label={t("media.player")} controls autoPlay playsInline />
        ) : (
          <>
            {openImage ? (
              <button
                type="button"
                className="cv-reel__open"
                title={t("image.view")}
                onClick={() => openImage(frame.src, frame.label)}
              >
                {picture}
              </button>
            ) : (
              picture
            )}
            {frame.click && (
              <span
                key={`mark-${shown}`}
                className="cv-reel__mark"
                aria-hidden="true"
                style={{
                  left: `${box.left + frame.click.x * box.width}%`,
                  top: `${box.top + frame.click.y * box.height}%`,
                }}
              />
            )}
            {video && (
              <button
                type="button"
                className="ui-glass cv-media__play cv-reel__play"
                aria-label={t("media.play")}
                onClick={() => setPlaying(true)}
              >
                <PlayTriangle size={18} style={{ color: "inherit" }} />
              </button>
            )}
          </>
        )}
      </div>
      <figcaption className="cv-reel__caption" data-failed={frame.ok === false || undefined}>
        {caption}
      </figcaption>
      {frames.length > 1 && (
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- the strip owns the arrow keys for its roving-tabindex buttons.
        <div
          className="cv-reel__strip"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a fieldset would draw a form border and need a legend.
          role="group"
          aria-label={t("reel.steps")}
          onKeyDown={onKeyDown}
          onPointerLeave={() => setHovered(undefined)}
        >
          {frames.map((item, index) => (
            <button
              // oxlint-disable-next-line react/no-array-index-key -- steps are positional; a reel never reorders.
              key={index}
              type="button"
              className="cv-reel__thumb"
              data-failed={item.ok === false || undefined}
              aria-current={index === selected ? "step" : undefined}
              aria-label={item.label}
              tabIndex={index === selected ? 0 : -1}
              onPointerEnter={() => setHovered(index)}
              onFocus={() => setHovered(undefined)}
              onClick={() => step(index)}
            >
              <img src={item.src} alt="" loading="lazy" decoding="async" />
            </button>
          ))}
        </div>
      )}
    </figure>
  );
}
