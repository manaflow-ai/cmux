// l10n-allow-file: gallery board (look names and sizes), not shipped UI.
// The agent working-state mark's candidates side by side, in light and dark, at the sidebar's
// sizes (12 and 14 px) and the transcript's (16 px). Only "ring-sweep" is the real `Spinner`; the
// arc and the spokes are the two rejected marks (Leo 2026-10-31: "who even decided to put that 3/4
// circle"; 2026-11-01, on the spokes: "why the f*** did you make the spinner into this????"), and
// the conic sweep is the runner-up, drawn here only.
import "./SpinnerLooksBoard.css";
import { Spinner } from "./icons";

export type SpinnerLook = "ring-sweep" | "conic" | "arc" | "spokes";

export type SpinnerLooksBoardProps = {
  /** The looks to draw, one row each, in order. */
  looks: SpinnerLook[];
};

const LABELS: Record<SpinnerLook, string> = {
  "ring-sweep": "(b) Ring + sweep (shipped)",
  conic: "(c) Conic sweep",
  arc: "3/4 arc (rejected 2026-10-31)",
  spokes: "Spokes (rejected 2026-11-01)",
};

const SIZES = [12, 14, 16];

/** The spokes #29903 shipped (eight, the macOS activity indicator's), for reference only. */
const SPOKES = Array.from({ length: 8 }, (_, index) => ({
  angle: index * 45,
  opacity: index === 0 ? 1 : Math.max(0.25, 1 - (8 - index) * 0.11),
}));

function Mark({ look, size }: { look: SpinnerLook; size: number }) {
  switch (look) {
    case "ring-sweep":
      return <Spinner size={size} />;
    case "arc":
      return <Spinner size={size} loading />;
    case "conic":
      return <span className="spinner-looks__conic" style={{ width: size, height: size }} aria-hidden="true" />;
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
