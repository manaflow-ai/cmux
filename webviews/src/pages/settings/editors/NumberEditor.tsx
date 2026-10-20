import { useEffect, useRef, useState } from "react";
import { useSettingsSelector, useStore } from "../context";
import { effectiveNumber } from "../inheritance";
import { text } from "../strings";
import { NumberField } from "./NumberField";
import type { EditorProps } from "./types";

/**
 * Slider + field. While the slider moves the page sends `preview` (never written); releasing
 * it sends one `settings.set`, then `preview.end`. The field commits on Return or blur.
 *
 * Unset, both sit on the live value when the page knows it (`effectiveNumber`: the window's
 * opacity for a surface, the value the app resolved), dimmed with a badge naming where it comes
 * from, so a click or a drag starts where the thumb is drawn instead of jumping from a placeholder.
 */
export function NumberEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const effective = useSettingsSelector((state) => effectiveNumber(state, row)?.value ?? null);
  const badge = useSettingsSelector((state) => effectiveNumber(state, row)?.badge ?? null);
  const known = useSettingsSelector((state) => effectiveNumber(state, row)?.known ?? false);
  const range = row.range!;
  const stored = typeof value === "number" ? value : null;
  const [drag, setDrag] = useState<number | null>(null);
  const pending = useRef<number | null>(null);
  const slider = useRef<HTMLInputElement | null>(null);
  const current = drag ?? stored ?? effective ?? range.placeholder;
  const release = () => {
    const next = pending.current;
    if (next === null) return;
    pending.current = null;
    // Write first, then end the preview: the window keeps the new value and never flashes the old.
    // The thumb keeps the released value until the write answered, so it never snaps back to the
    // unset value (the field read "Ghostty") while the write is in flight.
    if (next === stored) {
      setDrag(null);
      store.previewEnd(row.key);
      return;
    }
    void store.set(row.key, next).then(() => {
      store.previewEnd(row.key);
      if (pending.current === null) setDrag(null);
    });
  };
  const releaseRef = useRef(release);
  releaseRef.current = release;
  // The native `change` event fires once when a drag or a click on the track ends, wherever the
  // pointer is then; React's onChange is the per-step `input` event.
  useEffect(() => {
    const element = slider.current;
    if (!element) return;
    const onCommit = () => releaseRef.current();
    element.addEventListener("change", onCommit);
    return () => element.removeEventListener("change", onCommit);
  }, []);
  const inherited = drag === null && stored === null && known;
  return (
    <span className="number-editor" data-inherited={inherited ? "" : undefined}>
      {inherited && badge && <span className="inherit-badge">{badge}</span>}
      <input
        ref={slider}
        type="range"
        className="slider"
        min={range.min}
        max={range.max}
        step={range.step}
        value={current}
        // A range with no travel (Opacity over a picture whose legibility floor reaches its cap).
        disabled={disabled || range.min >= range.max}
        aria-labelledby={labelId}
        onChange={(event) => {
          const next = Math.min(Math.max(Number(event.currentTarget.value), range.min), range.max);
          pending.current = next;
          setDrag(next);
          store.preview(row.key, next);
        }}
        onPointerDown={(event) => {
          // The release reaches the slider even when the pointer leaves it mid-drag.
          event.currentTarget.setPointerCapture?.(event.pointerId);
        }}
        onPointerUp={release}
        onKeyUp={release}
        onBlur={release}
      />
      <NumberField
        value={drag ?? stored}
        inherited={inherited ? effective : null}
        range={range}
        placeholder={text(row.default_label)}
        disabled={disabled}
        labelId={labelId}
        onCommit={(next) => void store.set(row.key, next)}
      />
    </span>
  );
}
