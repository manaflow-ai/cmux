import { useRef, useState } from "react";
import { useStore } from "../context";
import { text } from "../strings";
import { NumberField } from "./NumberField";
import type { EditorProps } from "./types";

/**
 * Slider + field. While the slider moves the page sends `preview` (never written); releasing
 * it sends one `settings.set`, then `preview.end`. The field commits on Return or blur.
 */
export function NumberEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const range = row.range!;
  const stored = typeof value === "number" ? value : null;
  const [drag, setDrag] = useState<number | null>(null);
  const pending = useRef<number | null>(null);
  const current = drag ?? stored ?? range.placeholder;
  const release = () => {
    const next = pending.current;
    if (next === null) return;
    pending.current = null;
    setDrag(null);
    // Write first, then end the preview: the window keeps the new value and never flashes the old.
    if (next === stored) store.previewEnd(row.key);
    else void store.set(row.key, next).then(() => store.previewEnd(row.key));
  };
  return (
    <span className="number-editor">
      <input
        type="range"
        className="slider"
        min={range.min}
        max={range.max}
        step={range.step}
        value={current}
        disabled={disabled}
        aria-labelledby={labelId}
        onChange={(event) => {
          const next = Number(event.currentTarget.value);
          pending.current = next;
          setDrag(next);
          store.preview(row.key, next);
        }}
        onPointerUp={release}
        onKeyUp={release}
        onBlur={release}
      />
      <NumberField
        value={drag ?? stored}
        range={range}
        placeholder={text(row.default_label)}
        disabled={disabled}
        labelId={labelId}
        onCommit={(next) => void store.set(row.key, next)}
      />
    </span>
  );
}
