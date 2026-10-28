// The Reading Settings text width control (user 2026-10-19: "text width to be much more flexible ...
// super super wide text width ... but they don't want it to be actually full width"; then "what if
// someone wants to type in a value instead of using a slider ... think about how apps like Microsoft
// Word or Figma will make this look and feel"). The pattern of a design tool's dimension field:
//
// - the number field is the main control: type `120`, `120ch`, `1600pt` or `72*2`, then Return or
//   leave the field; Escape puts the value back. A value out of range takes the nearest end and the
//   field shows it.
// - Up and Down step by 1 character, Shift by 10; so do the field's small stepper buttons.
// - dragging the label sideways scrubs the value (Figma), Shift for steps of 10.
// - the preset menu next to it, as Word's page margins: Narrow, Comfortable, Wide, Extra Wide,
//   Ultra Wide, Full Width, and Custom when the width is none of them.
//
// No slider: 30 to 1000 characters in a 280pt popover is about 3.5 characters a pixel, too coarse
// to pick a reading width and too fine to find a big one. Full width is a preset, never the top of
// the range, so a huge width still keeps margins on a wider screen.
import { useId, useRef, useState, type KeyboardEvent, type PointerEvent } from "react";
import { Select } from "../../ui/Select";
import type { Strings } from "../shared/i18n";
import {
  MARKDOWN_READING,
  MARKDOWN_WIDTH_PRESETS,
  clampWidth,
  markdownWidthPreset,
  measureCharacterWidth,
  parseWidthInput,
  type MarkdownWidthPreset,
} from "./settings";
import { L } from "./strings";

export interface WidthFieldProps {
  width: number;
  fullWidth: boolean;
  strings: Strings;
  /** A new width in characters; also leaves full width. */
  setWidth(width: number): void;
  setFullWidth(fullWidth: boolean): void;
  /** One character of the reading font in CSS pixels (for `pt` input); measured on the page by default. */
  characterWidth?: () => number;
}

const PRESET_LABEL: Record<MarkdownWidthPreset, string> = {
  narrow: L.readingWidthNarrow,
  comfortable: L.readingWidthComfortable,
  wide: L.readingWidthWide,
  extraWide: L.readingWidthExtraWide,
  ultraWide: L.readingWidthUltraWide,
  fullWidth: L.readingFullWidth,
  custom: L.readingWidthCustom,
};

/** Pixels of pointer travel per character while scrubbing the label. */
const SCRUB_PIXELS_PER_STEP = 2;

export function WidthField({ width, fullWidth, strings, setWidth, setFullWidth, characterWidth }: WidthFieldProps) {
  const { t, format } = strings;
  const id = useId();
  const input = useRef<HTMLInputElement>(null);
  const [draft, setDraft] = useState<string | null>(null);
  const [invalid, setInvalid] = useState(false);
  const scrub = useRef<{ x: number; from: number; last: number } | null>(null);
  const range = MARKDOWN_READING.width;
  const chPixels = () => (characterWidth ?? (() => measureCharacterWidth()))();
  const preset = markdownWidthPreset({ width, fullWidth });

  const apply = (next: number) => {
    const clamped = clampWidth(next);
    if (clamped !== width || fullWidth) setWidth(clamped);
    return clamped;
  };

  const commit = () => {
    if (draft === null) return;
    const parsed = parseWidthInput(draft, chPixels());
    setDraft(null);
    if (parsed === null) {
      setInvalid(true);
      return;
    }
    setInvalid(false);
    apply(parsed);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter") {
      event.preventDefault();
      commit();
      input.current?.select();
    } else if (event.key === "Escape" && draft !== null) {
      // Revert only; a second Escape closes the popover.
      event.preventDefault();
      event.stopPropagation();
      setDraft(null);
      setInvalid(false);
    } else if (event.key === "ArrowUp" || event.key === "ArrowDown") {
      event.preventDefault();
      const base = draft !== null ? (parseWidthInput(draft, chPixels()) ?? width) : width;
      const step = (event.shiftKey ? range.bigStep : range.step) * (event.key === "ArrowUp" ? 1 : -1);
      setDraft(null);
      setInvalid(false);
      apply(base + step);
    }
  };

  const onScrubStart = (event: PointerEvent<HTMLElement>) => {
    if (event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture?.(event.pointerId);
    scrub.current = { x: event.clientX, from: width, last: width };
  };
  const onScrubMove = (event: PointerEvent<HTMLElement>) => {
    const state = scrub.current;
    if (!state) return;
    const steps = Math.trunc((event.clientX - state.x) / SCRUB_PIXELS_PER_STEP);
    const next = clampWidth(state.from + steps * (event.shiftKey ? range.bigStep : range.step));
    if (next === state.last && !fullWidth) return;
    state.last = next;
    setDraft(null);
    setInvalid(false);
    setWidth(next);
  };
  const onScrubEnd = (event: PointerEvent<HTMLElement>) => {
    if (!scrub.current) return;
    scrub.current = null;
    event.currentTarget.releasePointerCapture?.(event.pointerId);
  };

  const step = (direction: 1 | -1, big: boolean) => apply(width + (big ? range.bigStep : range.step) * direction);

  const choosePreset = (value: string) => {
    if (value === "custom") {
      input.current?.focus();
      input.current?.select();
      return;
    }
    if (value === "fullWidth") {
      setFullWidth(true);
      return;
    }
    const chosen = MARKDOWN_WIDTH_PRESETS.find((option) => option.id === value);
    if (chosen && "width" in chosen) setWidth(chosen.width);
  };

  const options = (Object.keys(PRESET_LABEL) as MarkdownWidthPreset[])
    .filter((option) => option !== "custom" || preset === "custom")
    .map((option) => ({ value: option, label: t(PRESET_LABEL[option]) }));

  return (
    <div className="md-reading-row md-width">
      <label
        className="md-reading-label md-width-scrub"
        htmlFor={id}
        onPointerDown={onScrubStart}
        onPointerMove={onScrubMove}
        onPointerUp={onScrubEnd}
        onPointerCancel={onScrubEnd}
      >
        {t(L.readingWidth)}
      </label>
      <div className="md-width-controls">
        <div className="md-width-field" data-invalid={invalid || undefined} data-dimmed={fullWidth || undefined}>
          <input
            ref={input}
            id={id}
            className="md-width-input"
            type="text"
            inputMode="decimal"
            spellCheck={false}
            autoComplete="off"
            aria-label={t(L.readingWidth)}
            aria-invalid={invalid || undefined}
            title={t(L.readingWidthHint)}
            value={draft ?? String(width)}
            onFocus={(event) => event.currentTarget.select()}
            onChange={(event) => setDraft(event.currentTarget.value)}
            onBlur={commit}
            // ui-allow: the width field's own editing keys (Return applies, Esc puts the value back, Up and Down step), as a design tool's dimension field.
            onKeyDown={onKeyDown}
          />
          <span className="md-width-unit" aria-hidden="true">
            {t(L.readingWidthUnit)}
          </span>
          <span className="md-width-stepper">
            <button
              type="button"
              // ui-allow: the stepper repeats the field's Up and Down keys for the pointer, so Tab skips it.
              tabIndex={-1}
              aria-label={t(L.readingWidthIncrease)}
              onClick={(event) => step(1, event.shiftKey)}
            >
              <span aria-hidden="true">▴</span>
            </button>
            <button
              type="button"
              // ui-allow: the stepper repeats the field's Up and Down keys for the pointer, so Tab skips it.
              tabIndex={-1}
              aria-label={t(L.readingWidthDecrease)}
              onClick={(event) => step(-1, event.shiftKey)}
            >
              <span aria-hidden="true">▾</span>
            </button>
          </span>
        </div>
        <Select
          className="md-width-presets"
          label={t(L.readingWidthPresets)}
          value={preset}
          options={options}
          onChange={choosePreset}
          closeOnPick
        />
      </div>
      <output className="md-width-approx" htmlFor={id}>
        {format(L.readingWidthApprox, String(Math.round(width * chPixels())))}
      </output>
    </div>
  );
}
