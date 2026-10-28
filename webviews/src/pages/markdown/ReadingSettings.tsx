// The Reading Settings popover (user 2026-10-19: "make it easier to adjust tons of settings in
// markdown viewer like max width"): the toolbar's Aa button opens it. Every row is one `markdown.*`
// settings key (settings.ts MARKDOWN_READING; the same rows are in Settings > Appearance > Markdown
// Viewer and in cmux.json). A change shows at once and is written through the host
// (MarkdownStore.setPreference), so it persists and every open viewer follows it. Reset removes
// every key the popover edits. The text width row is WidthField (a typed field, stepper, scrubbing
// label and a preset menu, not a slider).
import { useId, type ReactNode } from "react";
import { Popover, type UiAnchor } from "../../ui/Popover";
import type { Strings } from "../shared/i18n";
import {
  MARKDOWN_READING,
  markdownReadingValues,
  type MarkdownFontPreset,
  type MarkdownReadingOption,
  type MarkdownTables,
  type MarkdownTheme,
} from "./settings";
import { L } from "./strings";
import { WidthField } from "./WidthField";

/** What the popover changes: one option's value, or null to reset every option. */
export interface ReadingSettingsActions {
  set(option: MarkdownReadingOption, value: number | boolean | string): void;
  reset(): void;
}

export interface ReadingSettingsProps {
  open: boolean;
  onOpenChange(open: boolean): void;
  anchor: UiAnchor;
  settings: unknown;
  strings: Strings;
  actions: ReadingSettingsActions;
}

/** A number shown with at most two decimals and no trailing zeros. */
const shown = (value: number) => String(Number(value.toFixed(2)));

export function ReadingSettings({ open, onOpenChange, anchor, settings, strings, actions }: ReadingSettingsProps) {
  const { t, format } = strings;
  const percent = new Intl.NumberFormat(strings.language, { style: "percent", maximumFractionDigits: 0 });
  const values = markdownReadingValues(settings);
  const r = MARKDOWN_READING;
  return (
    <Popover
      open={open}
      onOpenChange={(next) => onOpenChange(next)}
      anchor={anchor}
      label={t(L.readingTitle)}
      className="md-reading"
      side="bottom"
    >
      <div className="md-reading-body">
        <WidthField
          width={values.width}
          fullWidth={values.fullWidth}
          strings={strings}
          setWidth={(width) => {
            if (values.fullWidth) actions.set("fullWidth", false);
            actions.set("width", width);
          }}
          setFullWidth={(fullWidth) => actions.set("fullWidth", fullWidth)}
        />
        <Slider
          label={t(L.readingFontSize)}
          value={values.fontSize}
          range={r.fontSize}
          display={format(L.readingPoints, String(values.fontSize))}
          onChange={(value) => actions.set("fontSize", value)}
        />
        <Choice<MarkdownFontPreset>
          label={t(L.readingFont)}
          value={values.fontPreset}
          options={[
            ["system", t(L.readingFontSystem)],
            ["serif", t(L.readingFontSerif)],
            ["mono", t(L.readingFontMono)],
          ]}
          onChange={(value) => actions.set("fontPreset", value)}
        />
        <Slider
          label={t(L.readingLineHeight)}
          value={values.lineHeight}
          range={r.lineHeight}
          display={shown(values.lineHeight)}
          onChange={(value) => actions.set("lineHeight", value)}
        />
        <Slider
          label={t(L.readingParagraph)}
          value={values.paragraph}
          range={r.paragraph}
          display={percent.format(values.paragraph)}
          onChange={(value) => actions.set("paragraph", value)}
        />
        <Slider
          label={t(L.readingCodeSize)}
          value={values.codeScale}
          range={r.codeScale}
          display={percent.format(values.codeScale)}
          onChange={(value) => actions.set("codeScale", value)}
        />
        <Choice<MarkdownTables>
          label={t(L.readingTables)}
          value={values.tables}
          options={[
            ["scroll", t(L.readingTablesScroll)],
            ["wrap", t(L.readingTablesWrap)],
          ]}
          onChange={(value) => actions.set("tables", value)}
        />
        <Choice<MarkdownTheme>
          label={t(L.readingTheme)}
          value={values.theme}
          options={[
            ["app", t(L.readingThemeApp)],
            ["light", t(L.readingThemeLight)],
            ["dark", t(L.readingThemeDark)],
          ]}
          onChange={(value) => actions.set("theme", value)}
        />
        <div className="md-reading-footer">
          <button type="button" className="md-button" onClick={() => actions.reset()}>
            {t(L.readingReset)}
          </button>
        </div>
      </div>
    </Popover>
  );
}

function Row({ label, id, value, children }: { label: string; id: string; value?: string; children: ReactNode }) {
  return (
    <div className="md-reading-row">
      <label className="md-reading-label" htmlFor={id}>
        {label}
      </label>
      {value !== undefined ? (
        <output className="md-reading-value" htmlFor={id}>
          {value}
        </output>
      ) : null}
      {children}
    </div>
  );
}

function Slider({
  label,
  value,
  range,
  display,
  disabled,
  onChange,
}: {
  label: string;
  value: number;
  range: { min: number; max: number; step: number };
  display: string;
  disabled?: boolean;
  onChange(value: number): void;
}) {
  const id = useId();
  return (
    <Row label={label} id={id} value={display}>
      <input
        id={id}
        aria-label={label}
        className="md-reading-slider"
        type="range"
        min={range.min}
        max={range.max}
        step={range.step}
        value={value}
        disabled={disabled}
        onChange={(event) => onChange(Number(event.currentTarget.value))}
      />
    </Row>
  );
}

function Choice<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: Array<[T, string]>;
  onChange(value: T): void;
}) {
  const name = useId();
  return (
    <fieldset className="md-reading-row md-reading-choice">
      <legend className="md-reading-label">{label}</legend>
      <div className="md-reading-segments">
        {options.map(([option, text]) => (
          <label key={option} className="md-reading-segment" data-checked={option === value || undefined}>
            <input
              type="radio"
              aria-label={text}
              name={name}
              value={option}
              checked={option === value}
              onChange={() => onChange(option)}
            />
            <span>{text}</span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}
