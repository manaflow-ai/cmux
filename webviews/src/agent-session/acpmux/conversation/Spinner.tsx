// The one working mark every spinner draws. Its own module, importing no icon pack, so a page that needs only the
// spinner (the diff viewer) stays small.
import type { CSSProperties } from "react";
import "./spinner.css";

type SpinnerProps = {
  size?: number;
  className?: string;
  style?: CSSProperties;
  loading?: boolean;
  strokeWidth?: number;
  look?: SpinnerLook;
};

/// The working mark. `arc` (the default) is the open arc every spinner draws; `track` is a three-quarter ring with rounded caps on a faint full
/// ring: still, it reads as a ring part way round, never as the letter "C" an open arc alone draws
/// (Leo, 2026-11-21: "this spinner is incredibly ugly"). `arc` is the open arc this replaced and
/// `dots` three pulsing dots; both stay for the gallery's side by sides (BackgroundSpinner.gallery.ts).
export type SpinnerLook = "track" | "arc" | "dots";

export const Spinner = ({ size = 16, className, style, strokeWidth, loading = false, look = "arc" }: SpinnerProps) => {
  // The ring takes the line icons' weight (iconSize.ts ICON_STROKE) so it sits with the clock and terminal beside it.
  const weight = strokeWidth ?? (look === "track" ? 1.25 : 1.5);
  return (
    <svg
      className={`cv-spinner${look === "dots" ? " cv-spinner--dots" : ""}${className ? ` ${className}` : ""}`}
      style={style}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      aria-hidden="true"
      data-working={loading ? undefined : ""}
      data-spinner-look={look}
    >
      {look === "dots" ? (
        [3.5, 8, 12.5].map((cx, i) => (
          <circle
            key={cx}
            className="cv-spinner__pip"
            cx={cx}
            cy="8"
            r="1.4"
            fill="currentColor"
            style={{ animationDelay: `${i * 160}ms` }}
          />
        ))
      ) : (
        <>
          {look === "track" && (
            <circle className="cv-spinner__track" cx="8" cy="8" r="5.75" stroke="currentColor" strokeWidth={weight} />
          )}
          <path
            className="cv-spinner__arc"
            d={look === "track" ? "M8 2.25A5.75 5.75 0 1 1 2.25 8" : "M8 2.75a5.25 5.25 0 1 1-4.55 2.63"}
            stroke="currentColor"
            strokeWidth={weight}
            strokeLinecap="round"
          />
        </>
      )}
      {!loading && look !== "dots" && <circle className="cv-spinner__dot" cx="8" cy="8" r="3" />}
    </svg>
  );
};
