// Placing a Chief's picture in its circle (backgrounds plan phase 4): drag to move, the slider
// zooms. A GIF is not placed here; it keeps its motion and is drawn centered.
import { useRef } from "react";
import { cropSquare, dragCrop, MAX_ZOOM, type PictureCrop as Crop } from "./picture";

const VIEW = 160;

export function PictureCrop({
  url,
  size,
  crop,
  onChange,
  labels,
}: {
  url: string;
  size: { width: number; height: number };
  crop: Crop;
  onChange: (crop: Crop) => void;
  labels: { zoom: string; hint: string };
}) {
  const drag = useRef<{ x: number; y: number } | null>(null);
  const square = cropSquare(size.width, size.height, crop);
  const scale = VIEW / square.side;
  return (
    <div className="lg-picture-crop">
      <div
        className="lg-picture-crop-view"
        style={{ width: VIEW, height: VIEW }}
        // The pointer places the picture; the slider and the hint below are what assistive tech reads.
        aria-hidden="true"
        onPointerDown={(event) => {
          drag.current = { x: event.clientX, y: event.clientY };
          event.currentTarget.setPointerCapture?.(event.pointerId);
        }}
        onPointerMove={(event) => {
          if (!drag.current) return;
          const dx = event.clientX - drag.current.x;
          const dy = event.clientY - drag.current.y;
          drag.current = { x: event.clientX, y: event.clientY };
          onChange(dragCrop(crop, size.width, size.height, VIEW, dx, dy));
        }}
        onPointerUp={() => (drag.current = null)}
        onPointerCancel={() => (drag.current = null)}
      >
        <img
          src={url}
          alt=""
          draggable={false}
          style={{
            width: size.width * scale,
            height: size.height * scale,
            left: -square.x * scale,
            top: -square.y * scale,
          }}
        />
      </div>
      <label className="lg-form-row">
        <span className="lg-form-label">{labels.zoom}</span>
        <input
          type="range"
          min={1}
          max={MAX_ZOOM}
          step={0.01}
          value={crop.zoom}
          aria-label={labels.zoom}
          onChange={(event) => onChange({ ...crop, zoom: Number(event.target.value) })}
        />
      </label>
      <span className="lg-form-note">{labels.hint}</span>
    </div>
  );
}
