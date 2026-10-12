// The theme's colors as swatches, each one editable (cx-wqn5, Procreate-style): a click or Return
// opens a tuner with OKLCH lightness, chroma and hue sliders, a hex field, the colors it snaps to
// (the theme's own and the nearest of every other theme), the contrast it keeps with a fix when it
// falls below its floor, and Reset. The app shows each change live (onPreview); Done or a click
// outside keeps it as the theme's edit (appearance.themeEdits), Escape reverts. The theme itself
// never changes: its edits make "<theme> (custom)".
import { useState } from "react";
import { Popover } from "../../../ui/Popover";
import type { GhosttyTheme } from "../../../theme/ghosttyTheme";
import { THEME_EDIT_TOKENS, editsFor, type ThemeEditToken } from "../../../theme/themeEdits";
import {
  contrastFloor,
  hexFromOklch,
  magnet,
  meetFloor,
  oklchFromHex,
  snapColors,
  tokenColor,
  tokenContrast,
} from "../../../theme/tokenTuning";
import { t } from "../strings";

const NAMED: ThemeEditToken[] = ["background", "foreground", "cursor", "selection", "accent"];

/** A token's name as the page shows it. */
function tokenLabel(token: ThemeEditToken): string {
  switch (token) {
    case "background":
      return t("settingsPage.theme.background");
    case "foreground":
      return t("settingsPage.theme.foreground");
    case "cursor":
      return t("settingsPage.theme.cursor");
    case "selection":
      return t("settingsPage.theme.selection");
    case "accent":
      return t("settingsPage.theme.accent");
    default:
      return t("settingsPage.theme.edit.ansi", token);
  }
}

export function ThemeTokens({
  theme,
  base,
  edits,
  others,
  editable,
  onPreview,
  onCommit,
}: {
  /** The theme with its edits, as the app draws it. */
  theme: GhosttyTheme;
  /** The theme as it ships, for Reset. */
  base: GhosttyTheme;
  /** appearance.themeEdits as stored. */
  edits: Readonly<Record<string, string>> | null;
  /** Every theme, for the colors a token snaps to. */
  others: Iterable<GhosttyTheme>;
  /** False while no named theme is chosen (the Ghostty config's own colors) or the key is managed. */
  editable: boolean;
  /** Shows `token` as `color` live in the app; null ends the preview. */
  onPreview(token: ThemeEditToken, color: string | null): void;
  /** Keeps `token` as `color`; null resets it to the theme's own. */
  onCommit(token: ThemeEditToken, color: string | null): void | Promise<unknown>;
}) {
  const [editing, setEditing] = useState<{ token: ThemeEditToken; anchor: HTMLElement } | null>(null);
  const edited = editsFor(edits, theme.name);
  const swatch = (token: ThemeEditToken) => {
    const color = tokenColor(theme, token);
    return (
      <button
        key={token}
        type="button"
        className="theme-token"
        data-token={token}
        data-edited={edited[token] ? "" : undefined}
        disabled={!editable}
        aria-label={`${tokenLabel(token)} ${color}`}
        aria-haspopup="dialog"
        aria-expanded={editing?.token === token}
        title={editable ? `${tokenLabel(token)} ${color}` : t("settingsPage.theme.edit.pickTheme")}
        style={{ background: color }}
        onClick={(event) => setEditing({ token, anchor: event.currentTarget })}
      />
    );
  };
  return (
    <fieldset className="theme-tokens" aria-label={t("settingsPage.theme.palette")}>
      <div className="theme-tokens-row">
        <span className="theme-tokens-label">{t("settingsPage.theme.normal")}</span>
        {THEME_EDIT_TOKENS.slice(4, 12).map(swatch)}
      </div>
      <div className="theme-tokens-row">
        <span className="theme-tokens-label">{t("settingsPage.theme.bright")}</span>
        {THEME_EDIT_TOKENS.slice(12, 20).map(swatch)}
      </div>
      <div className="theme-tokens-named">
        {NAMED.map((token) => (
          <span key={token} className="theme-tokens-pair">
            {swatch(token)}
            <span className="theme-tokens-name">{tokenLabel(token)}</span>
            <span className="theme-tokens-hex">{tokenColor(theme, token)}</span>
          </span>
        ))}
      </div>
      {editing && (
        <TokenTuner
          key={editing.token}
          theme={theme}
          base={base}
          token={editing.token}
          anchor={editing.anchor}
          others={others}
          edited={edited[editing.token] !== undefined}
          onPreview={(color) => onPreview(editing.token, color)}
          onDone={(color) => {
            setEditing(null);
            // Write first, then end the preview: the app goes from the preview to the same saved color.
            const kept = color === undefined ? Promise.resolve() : Promise.resolve(onCommit(editing.token, color));
            void kept.finally(() => onPreview(editing.token, null));
          }}
        />
      )}
    </fieldset>
  );
}

/** The tuner of one token. `onDone(undefined)` reverts; a color (or null, Reset) keeps it. */
function TokenTuner({
  theme,
  base,
  token,
  anchor,
  others,
  edited,
  onPreview,
  onDone,
}: {
  theme: GhosttyTheme;
  base: GhosttyTheme;
  token: ThemeEditToken;
  anchor: HTMLElement;
  others: Iterable<GhosttyTheme>;
  edited: boolean;
  onPreview(color: string): void;
  onDone(color: string | null | undefined): void;
}) {
  const start = tokenColor(theme, token);
  const [color, setColor] = useState(start);
  const [hex, setHex] = useState(start);
  // The sliders' own channels: a gray's hue, or a step too small to change the hex, still moves them.
  const [lch, setLch] = useState(() => oklchFromHex(start));
  const [snaps] = useState(() => snapColors(theme, token, start, others));
  const floor = contrastFloor(token);
  const ratio = tokenContrast(theme, token, color);
  const low = floor !== null && ratio !== null && ratio < floor.min;

  const show = (next: string, channels = oklchFromHex(next)) => {
    setColor(next);
    setHex(next);
    setLch(channels);
    onPreview(next);
  };
  const slide = (channel: "l" | "c" | "h", value: number) => {
    const channels = { ...lch, [channel]: value };
    const raw = hexFromOklch(channels);
    const snapped = magnet(raw, snaps, color);
    show(snapped, snapped === raw ? channels : oklchFromHex(snapped));
  };
  const keep = () => onDone(color === start ? undefined : color);

  return (
    <Popover
      open
      // Escape reverts; any other close (a click outside) keeps the color.
      onOpenChange={(open, details) => !open && (details?.escape ? onDone(undefined) : keep())}
      anchor={anchor}
      label={t("settingsPage.theme.edit.title", tokenLabel(token))}
      className="token-tuner"
    >
      {/* Return in the hex field (its one text field) submits: it keeps the color, as Done does. */}
      <form
        className="token-tuner-body"
        data-token-tuner={token}
        onSubmit={(event) => {
          event.preventDefault();
          keep();
        }}
      >
        <div className="token-tuner-head">
          <span className="token-tuner-swatch" style={{ background: color }} />
          <span className="token-tuner-name">{tokenLabel(token)}</span>
          <input
            className="field token-tuner-hex"
            aria-label={t("settingsPage.theme.edit.hex")}
            spellCheck={false}
            value={hex}
            onChange={(event) => {
              const text = event.currentTarget.value.trim();
              setHex(text);
              if (/^#[0-9a-fA-F]{6}$/.test(text)) {
                const next = text.toLowerCase();
                setColor(next);
                setLch(oklchFromHex(next));
                onPreview(next);
              }
            }}
          />
        </div>
        <Slider
          label={t("settingsPage.theme.edit.lightness")}
          value={lch.l}
          max={1}
          step={0.005}
          track={[0, 0.5, 1].map((l) => hexFromOklch({ ...lch, l }))}
          onChange={(value) => slide("l", value)}
        />
        <Slider
          label={t("settingsPage.theme.edit.chroma")}
          value={lch.c}
          max={0.37}
          step={0.002}
          track={[0, 0.18, 0.37].map((c) => hexFromOklch({ ...lch, c }))}
          onChange={(value) => slide("c", value)}
        />
        <Slider
          label={t("settingsPage.theme.edit.hue")}
          value={lch.h}
          max={360}
          step={1}
          track={[0, 60, 120, 180, 240, 300, 360].map((h) => hexFromOklch({ l: lch.l, c: Math.max(lch.c, 0.1), h }))}
          onChange={(value) => slide("h", value)}
        />
        {snaps.length > 0 && (
          <fieldset className="token-tuner-snaps" aria-label={t("settingsPage.theme.edit.snap")}>
            {snaps.map((snap) => (
              <button
                key={snap}
                type="button"
                className="token-tuner-snap"
                data-snap={snap}
                aria-label={snap}
                title={snap}
                style={{ background: snap }}
                onClick={() => show(snap)}
              />
            ))}
          </fieldset>
        )}
        {ratio !== null && floor && (
          <div className="token-tuner-contrast" data-contrast-low={low ? "" : undefined}>
            <span>{t("settingsPage.theme.edit.contrast", ratio.toFixed(1), floor.min.toFixed(1))}</span>
            {low && (
              <button type="button" className="button" onClick={() => show(meetFloor(theme, token, color))}>
                {t("settingsPage.theme.edit.fixContrast")}
              </button>
            )}
          </div>
        )}
        <div className="token-tuner-actions">
          <button
            type="button"
            className="button"
            disabled={!edited && color === tokenColor(base, token)}
            onClick={() => onDone(null)}
          >
            {t("settingsPage.theme.edit.reset")}
          </button>
          <button type="button" className="button button-primary" onClick={keep}>
            {t("settingsPage.theme.edit.done")}
          </button>
        </div>
      </form>
    </Popover>
  );
}

/** One OKLCH channel: a range over a gradient of the color along that channel. */
function Slider({
  label,
  value,
  max,
  step,
  track,
  onChange,
}: {
  label: string;
  value: number;
  max: number;
  step: number;
  track: string[];
  onChange(value: number): void;
}) {
  return (
    <label className="token-tuner-slider">
      <span className="token-tuner-slider-label">{label}</span>
      <input
        type="range"
        aria-label={label}
        min={0}
        max={max}
        step={step}
        value={Math.min(value, max)}
        style={{ background: `linear-gradient(to right, ${track.join(", ")})` }}
        onChange={(event) => onChange(Number(event.currentTarget.value))}
      />
    </label>
  );
}
