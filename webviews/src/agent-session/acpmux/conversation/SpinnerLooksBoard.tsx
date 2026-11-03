// l10n-allow-file: gallery board (look names and sizes), not shipped UI.
// The agent working-state mark's candidates side by side, in light and dark, at the sidebar's
// sizes (12 and 14 px) and the transcript's (16 px). Only "gap-ring" is the real `Spinner`: ChatGPT's
// ring with one gap (Leo 2026-11-02: "THIS IS CHATGPT", "IT GOES SLOWER"). The other gap rings are the
// runners-up, drawn here only; "ring-sweep" is #31455's mark it replaced, and the loading arc and the
// spokes are for reference (2026-11-01, on the spokes: "why the f*** did you make the spinner into
// this????").
import type { CSSProperties } from "react";
import "./SpinnerLooksBoard.css";
import { Spinner, WORKING_TRACK_OPACITY, workingArcPath } from "./icons";

export type SpinnerLook =
  | "gap-ring"
  | "gap-ring-half"
  | "gap-ring-open"
  | "gap-ring-thin"
  | "gap-ring-faster"
  | "ring-sweep"
  | "arc"
  | "spokes";

export type SpinnerLooksBoardProps = {
  /** The looks to draw, one row each, in order. */
  looks: SpinnerLook[];
};

const LABELS: Record<SpinnerLook, string> = {
  "gap-ring": "(a) Gap ring, 0.72 arc + track, stroke 2, 1.4 s (shipped)",
  "gap-ring-half": "(b) Half arc + track (OpenAI's Work video)",
  "gap-ring-open": "(c) Open gap ring, 0.85 arc, no track",
  "gap-ring-thin": "(d) Gap ring at stroke 1.5",
  "gap-ring-faster": "(e) Gap ring at 1.0 s a turn",
  "ring-sweep": "80° sweep (#31455, replaced)",
  arc: "Loading arc (reference)",
  spokes: "Spokes (rejected 2026-11-01)",
};

/** A gap ring drawn here only: `share` of the ring bright, an optional faint track, `stroke` wide. */
function GapRing({
  size,
  share,
  track,
  stroke,
  style,
}: {
  size: number;
  share: number;
  track: boolean;
  stroke: number;
  style?: CSSProperties;
}) {
  return (
    <svg
      className="cv-spinner"
      style={style}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      aria-hidden="true"
    >
      {track && (
        <circle cx="8" cy="8" r="5.25" stroke="currentColor" strokeWidth={stroke} opacity={WORKING_TRACK_OPACITY} />
      )}
      <path d={workingArcPath(share)} stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" />
    </svg>
  );
}

/** #31455's mark: the faint ring with a short 80° sweep, for comparison. */
function RingSweep({ size }: { size: number }) {
  return (
    <svg className="cv-spinner" width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <circle cx="8" cy="8" r="5.25" stroke="currentColor" strokeWidth={1.5} opacity={0.22} />
      <path d={workingArcPath(0.22)} stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" />
    </svg>
  );
}

const SIZES = [12, 14, 16];

/** The spokes #29903 shipped (eight, the macOS activity indicator's), for reference only. */
const SPOKES = Array.from({ length: 8 }, (_, index) => ({
  angle: index * 45,
  opacity: index === 0 ? 1 : Math.max(0.25, 1 - (8 - index) * 0.11),
}));

function Mark({ look, size }: { look: SpinnerLook; size: number }) {
  switch (look) {
    case "gap-ring":
      return <Spinner size={size} />;
    case "gap-ring-half":
      return <GapRing size={size} share={0.5} track stroke={2} />;
    case "gap-ring-open":
      return <GapRing size={size} share={0.85} track={false} stroke={2} />;
    case "gap-ring-thin":
      return <GapRing size={size} share={0.72} track stroke={1.5} />;
    case "gap-ring-faster":
      return (
        <GapRing
          size={size}
          share={0.72}
          track
          stroke={2}
          style={{ "--cmux-spinner-period": "1000ms" } as CSSProperties}
        />
      );
    case "ring-sweep":
      return <RingSweep size={size} />;
    case "arc":
      return <Spinner size={size} loading />;
    case "spokes":
      return (
        <svg
          className="spinner-looks__spokes"
          width={size}
          height={size}
          viewBox="0 0 16 16"
          fill="none"
          aria-hidden="true"
        >
          <g stroke="currentColor" strokeWidth={1.5} strokeLinecap="round">
            {SPOKES.map(({ angle, opacity }) => (
              <line
                key={angle}
                x1="8"
                y1="1.75"
                x2="8"
                y2="4.75"
                opacity={opacity}
                transform={`rotate(${angle} 8 8)`}
              />
            ))}
          </g>
        </svg>
      );
  }
}

function Panel({ looks, scheme }: SpinnerLooksBoardProps & { scheme: "light" | "dark" }) {
  return (
    <div className="spinner-looks__panel" data-scheme={scheme}>
      <div className="spinner-looks__scheme">{scheme === "light" ? "Light" : "Dark"}</div>
      {looks.map((look) => (
        <div key={look} className="spinner-looks__row" data-look={look}>
          <span className="spinner-looks__label">{LABELS[look]}</span>
          {SIZES.map((size) => (
            <span key={size} className="spinner-looks__cell" title={`${size} px`}>
              <Mark look={look} size={size} />
            </span>
          ))}
        </div>
      ))}
    </div>
  );
}

/** Every candidate look in light and dark, at 12, 14 and 16 px. */
export function SpinnerLooksBoard({ looks }: SpinnerLooksBoardProps) {
  return (
    <div className="spinner-looks">
      <Panel looks={looks} scheme="light" />
      <Panel looks={looks} scheme="dark" />
    </div>
  );
}
