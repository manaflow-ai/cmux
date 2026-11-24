// The Background card's placement preview (Leo, 2026-11-22: "we also want people to be able to
// reposition the images easily. the fast-actions need to be most accessible."): the chosen picture
// in a window-shaped frame, dragged into place with the pointer or the arrow keys, and a Fill / Fit
// control. It draws with the same math the app does (../backgroundPlacement, Rust's mirror) and
// hands one placement on per gesture: on pointer up, a key, a segment or Reset.
import { useId, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import {
  CENTERED_FILL,
  isCenteredFill,
  placement,
  placementDragged,
  placementRect,
  type Placement,
  type Size,
} from "../backgroundPlacement";
import { t } from "../strings";

/** The frame's own size in the math's units: a window's usual 16:10. */
export const PREVIEW_VIEW: Size = { width: 1600, height: 1000 };
/** One arrow key moves the picture this much of the frame. */
const KEY_STEP = 0.05;

type Props = {
  /** The picture's address (its tile thumbnail). */
  src: string;
  /** Where it lies now (the setting's entry, else a centered fill). */
  value: Placement;
  /** The picture's size; read from the image once it loads when not given. */
  imageSize?: Size | null;
  disabled?: boolean;
  /** One placement per gesture. */
  onPlace: (next: Placement) => void;
};

const percent = (part: number, whole: number) => `${(part / whole) * 100}%`;

export function BackgroundPlacementPreview({ src, value, imageSize = null, disabled = false, onPlace }: Props) {
  const name = useId();
  const frame = useRef<HTMLDivElement | null>(null);
  const [loaded, setLoaded] = useState<Size | null>(null);
  // The placement under the pointer while a drag runs; the saved one otherwise.
  const [dragging, setDragging] = useState<{ x: number; y: number; from: Placement; now: Placement } | null>(null);
  // Before the picture loads it is taken as the frame's shape, so Fill shows it whole.
  const image = imageSize ?? loaded ?? PREVIEW_VIEW;
  const shown = dragging?.now ?? value;
  const rect = placementRect(shown, image, PREVIEW_VIEW);
  // Pointer points to the math's units.
  const scale = () => PREVIEW_VIEW.width / (frame.current?.clientWidth || PREVIEW_VIEW.width);
  const place = (next: Placement) => {
    if (next.mode !== value.mode || next.x !== value.x || next.y !== value.y || next.zoom !== value.zoom) onPlace(next);
  };
  const pickMode = (mode: "fill" | "fit") => place(placement(mode, value.x, value.y));
  return (
    <div className="placement-preview" data-placement-mode={shown.mode}>
      <div
        ref={frame}
        className="placement-frame"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a 2D drag surface; a range input has one axis.
        role="slider"
        tabIndex={disabled ? -1 : 0}
        aria-label={t("settingsWindow.backdropPlacement.preview")}
        aria-disabled={disabled || undefined}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Math.round(shown.x * 100)}
        aria-valuetext={`${Math.round(shown.x * 100)}%, ${Math.round(shown.y * 100)}%`}
        data-dragging={dragging ? "" : undefined}
        onPointerDown={(event) => {
          if (disabled || event.button !== 0) return;
          // Keeps the drag past the frame's edge; a synthetic event has no pointer to capture.
          try {
            event.currentTarget.setPointerCapture(event.pointerId);
          } catch {}
          setDragging({ x: event.clientX, y: event.clientY, from: value, now: value });
        }}
        onPointerMove={(event) => {
          if (!dragging) return;
          const k = scale();
          const now = placementDragged(
            dragging.from,
            image,
            PREVIEW_VIEW,
            (event.clientX - dragging.x) * k,
            (event.clientY - dragging.y) * k,
          );
          setDragging({ ...dragging, now });
        }}
        onPointerUp={() => {
          if (!dragging) return;
          setDragging(null);
          place(dragging.now);
        }}
        onPointerCancel={() => setDragging(null)}
        onKeyDown={(event) => {
          if (disabled) return;
          const step = {
            ArrowLeft: [-1, 0],
            ArrowRight: [1, 0],
            ArrowUp: [0, -1],
            ArrowDown: [0, 1],
          }[event.key];
          if (!step) return;
          event.preventDefault();
          const dx = step[0]! * PREVIEW_VIEW.width * KEY_STEP;
          const dy = step[1]! * PREVIEW_VIEW.height * KEY_STEP;
          place(placementDragged(value, image, PREVIEW_VIEW, dx, dy));
        }}
      >
        {rect && (
          <img
            className="placement-image"
            alt=""
            draggable={false}
            src={src}
            style={{
              left: percent(rect.x, PREVIEW_VIEW.width),
              top: percent(rect.y, PREVIEW_VIEW.height),
              width: percent(rect.width, PREVIEW_VIEW.width),
              height: percent(rect.height, PREVIEW_VIEW.height),
            }}
            onLoad={(event) => {
              const { naturalWidth: width, naturalHeight: height } = event.currentTarget;
              if (width > 0 && height > 0 && (loaded?.width !== width || loaded?.height !== height)) {
                setLoaded({ width, height });
              }
            }}
          />
        )}
      </div>
      <div className="placement-controls">
        <fieldset className="segmented" aria-label={t("settingsWindow.backdropPlacement.mode")} disabled={disabled}>
          {(["fill", "fit"] as const).map((mode) => (
            <label key={mode} className="segment" data-checked={value.mode === mode ? "" : undefined}>
              {/* oxlint-disable-next-line jsx-a11y/control-has-associated-label -- its label wraps it and its words. */}
              <input
                type="radio"
                name={name}
                value={mode}
                checked={value.mode === mode}
                onChange={() => pickMode(mode)}
              />
              {t(mode === "fill" ? "settingsWindow.backdropPlacement.fill" : "settingsWindow.backdropPlacement.fit")}
            </label>
          ))}
        </fieldset>
        {!isCenteredFill(value) && (
          <Button type="button" variant="ghost" size="sm" disabled={disabled} onClick={() => onPlace(CENTERED_FILL)}>
            {t("settingsWindow.backdropPlacement.reset")}
          </Button>
        )}
      </div>
      <p className="row-help">{t("settingsWindow.backdropPlacement.help")}</p>
    </div>
  );
}
