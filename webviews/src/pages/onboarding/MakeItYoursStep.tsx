// Make cmux Yours (cmux#48416, cmux#49636): a new person's one setup screen, each choice already on the
// recommended answer so Continue alone is a good setup:
//   1. How you work: Agents first (recommended; Cmd-T opens the New Tab page, where a chat starts) or
//      Terminal first (Cmd-T opens a terminal). The words never say "classic".
//   2. The look Settings > Appearance has, by its names and writing its keys:
//      - Density: every density Settings has, and Text Size (the density's until set; Default puts it back).
//      - Theme: the Ghostty config's (Default) or a few well-known families as light/dark pairs, each with
//        its swatches; Accent: every accent, each dot the color it gives the window's theme.
//      - Window Style: every style Settings has.
//      - Background: None, Shuffle Paintings or one of a few calm built-in works, then Opacity (how much
//        of the theme color covers the picture) and Material (None, Frosted, Glass, Clear Glass).
// Each choice is a group of native radios (the browser owns roles, arrows and focus); a pick is sent
// at once and the host writes it, so the app behind the window changes while the person watches.
// Continue keeps the picks; Skip (and Escape) puts back what was set when the window opened.
// Return presses Continue, Escape skips (the page's own key handler).
import { useRef, useState, type CSSProperties, type ReactNode } from "react";
import { cx } from "../../ui/cx";
import type { MakeItYoursMaterial, MakeItYoursState, MakeItYoursTheme, WorkStyle } from "./ops";
import { HostIcon, useOnboarding } from "./parts";

/** The two looks of the screen (the gallery's variant switch): `cards` ships. */
export type MakeItYoursLook = "cards" | "rows";
export const DEFAULT_MAKE_IT_YOURS_LOOK: MakeItYoursLook = "cards";

const WORK_STYLES: readonly WorkStyle[] = ["gui", "terminal"];
const WORK_KEYS: Record<WorkStyle, { title: string; detail: string }> = {
  gui: { title: "onboarding.makeItYours.work.gui", detail: "onboarding.makeItYours.work.gui.detail" },
  terminal: { title: "onboarding.makeItYours.work.terminal", detail: "onboarding.makeItYours.work.terminal.detail" },
};
const MATERIAL_KEYS: Record<MakeItYoursMaterial, string> = {
  none: "onboarding.makeItYours.material.none",
  frosted: "onboarding.makeItYours.material.frosted",
  glass: "onboarding.makeItYours.material.glass",
  "glass-clear": "onboarding.makeItYours.material.glass-clear",
};
/** Settings' accent names (an id the page does not know shows as itself). */
const ACCENT_KEYS: Record<string, string> = {
  neutral: "onboarding.makeItYours.accent.neutral",
  theme: "onboarding.makeItYours.accent.theme",
  red: "onboarding.makeItYours.accent.red",
  green: "onboarding.makeItYours.accent.green",
  yellow: "onboarding.makeItYours.accent.yellow",
  blue: "onboarding.makeItYours.accent.blue",
  magenta: "onboarding.makeItYours.accent.magenta",
  cyan: "onboarding.makeItYours.accent.cyan",
  art: "onboarding.makeItYours.accent.art",
};
/** Settings' window style names. */
const WINDOW_STYLE_KEYS: Record<string, string> = {
  default: "onboarding.makeItYours.windowStyle.default",
  card: "onboarding.makeItYours.windowStyle.card",
  "card-outlined": "onboarding.makeItYours.windowStyle.card-outlined",
  flat: "onboarding.makeItYours.windowStyle.flat",
  "flat-sidebar-line": "onboarding.makeItYours.windowStyle.flat-sidebar-line",
  bare: "onboarding.makeItYours.windowStyle.bare",
  panes: "onboarding.makeItYours.windowStyle.panes",
  "two-tone": "onboarding.makeItYours.windowStyle.two-tone",
  floating: "onboarding.makeItYours.windowStyle.floating",
  blocks: "onboarding.makeItYours.windowStyle.blocks",
};
/** The hues Art Color's dot turns through (the art's hue is not known before a window shows it). */
const ART_HUES = ["red", "yellow", "green", "cyan", "blue", "magenta"];

/** The value a radio carries for none (no background, the config's theme): an input's value is a string. */
const NONE = "";
/** The Opacity slider's step, as Settings' row. */
const OPACITY_STEP = 0.05;

const percent = (value: number) => `${Math.round(value * 100)}%`;
const points = (value: number) => `${Math.round(value * 2) / 2} pt`;

/** A slider row, as Settings' rows: a drag previews in the slider and is sent once on release (the host
 * takes one write per click or key); an arrow key sends its step at once. A value sent shows until the
 * host's state answers it, so the thumb never jumps back and two quick keys step twice. */
function SliderRow({
  id,
  label,
  value,
  min,
  max,
  step,
  format,
  onSend,
  children,
}: {
  id: string;
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  format: (value: number) => string;
  onSend: (value: number) => void;
  children?: ReactNode;
}) {
  const [drag, setDrag] = useState<number | null>(null);
  // The value sent while the host still shows `base`.
  const [sent, setSent] = useState<{ value: number; base: number } | null>(null);
  const dragging = useRef(false);
  const pending = useRef<number | null>(null);
  const current = sent !== null && sent.base === value ? sent.value : value;
  const send = (next: number) => {
    if (next === current) return;
    setSent({ value: next, base: value });
    onSend(next);
  };
  const release = () => {
    if (!dragging.current) return;
    dragging.current = false;
    const next = pending.current;
    pending.current = null;
    setDrag(null);
    if (next !== null) send(next);
  };
  const shown = drag ?? current;
  const labelId = `onb-make-${id}-label`;
  return (
    <div className="onb-make-adjust-row">
      <span className="onb-make-adjust-label" id={labelId}>
        {label}
      </span>
      <span className="onb-make-adjust-control">
        <input
          type="range"
          className="onb-make-slider"
          data-slider={id}
          min={min}
          max={max}
          step={step}
          value={shown}
          aria-labelledby={labelId}
          aria-valuetext={format(shown)}
          onPointerDown={() => {
            dragging.current = true;
          }}
          onChange={(event) => {
            const next = Number(event.currentTarget.value);
            if (dragging.current) {
              pending.current = next;
              setDrag(next);
              return;
            }
            // A key (or an assistive app's step): its own gesture, sent now.
            send(next);
          }}
          onPointerUp={release}
          onPointerCancel={release}
          onLostPointerCapture={release}
          onBlur={release}
        />
        <span className="onb-make-adjust-value" aria-hidden="true">
          {format(shown)}
        </span>
        {children}
      </span>
    </div>
  );
}

/** A labelled row of chip radios (Material, Accent, Window Style). */
function ChipRow({
  name,
  label,
  items,
  checked,
  onPick,
}: {
  name: string;
  label: string;
  items: { id: string; label: string; dot?: CSSProperties }[];
  checked: string | null;
  onPick: (id: string) => void;
}) {
  const labelId = `onb-make-${name}-label`;
  return (
    <div className="onb-make-adjust-row" role="radiogroup" aria-labelledby={labelId}>
      <span className="onb-make-adjust-label" id={labelId}>
        {label}
      </span>
      <div className="onb-make-chips">
        {items.map((item) => (
          <label key={item.id} className="onb-make-chip" data-checked={checked === item.id || undefined}>
            <input
              type="radio"
              name={name}
              value={item.id}
              aria-label={item.label}
              checked={checked === item.id}
              onChange={() => onPick(item.id)}
            />
            {item.dot && <span className="onb-make-dot" style={item.dot} aria-hidden="true" />}
            <span>{item.label}</span>
          </label>
        ))}
      </div>
    </div>
  );
}

/** One side of a theme's tile: its background with its six hues as bars and its text color as a line. */
function ThemeSide({ strip }: { strip: string[] }) {
  if (strip.length === 0) return <span className="onb-make-theme-side" />;
  const hues = strip.slice(1, -1);
  return (
    <span className="onb-make-theme-side" style={{ background: strip[0] }}>
      <span className="onb-make-theme-text" style={{ background: strip[strip.length - 1] }} />
      <span className="onb-make-theme-hues">
        {hues.map((hue, index) => (
          <span key={index} style={{ background: hue }} />
        ))}
      </span>
    </span>
  );
}

export function MakeItYoursStep({
  choices,
  look = DEFAULT_MAKE_IT_YOURS_LOOK,
}: {
  choices: MakeItYoursState | null | undefined;
  look?: MakeItYoursLook;
}) {
  const { strings, store } = useOnboarding();
  if (choices == null) return null;
  const backgrounds = [{ id: NONE, name: "", preview: null }, ...choices.backgrounds];
  const backgroundLabel = (id: string, name: string) =>
    id === NONE
      ? strings.t("onboarding.makeItYours.background.none")
      : id === "daily"
        ? strings.t("onboarding.makeItYours.background.shuffle")
        : name;
  const themes: MakeItYoursTheme[] = [{ id: NONE, name: "", light: [], dark: [] }, ...choices.themes];
  const swatches = choices.accentSwatches;
  const artHues = ART_HUES.flatMap((hue) => (swatches[hue] ? [swatches[hue]] : []));
  const accentDot = (accent: string): CSSProperties | undefined =>
    swatches[accent]
      ? { background: swatches[accent] }
      : accent === "art" && artHues.length > 1
        ? { background: `conic-gradient(${[...artHues, artHues[0]].join(", ")})` }
        : undefined;
  return (
    <div className="onb-make" data-look={look}>
      <fieldset className="onb-make-group onb-make-work">
        <legend className="onb-make-label">{strings.t("onboarding.makeItYours.work.label")}</legend>
        <div className="onb-make-options">
          {WORK_STYLES.map((style) => (
            <label key={style} className="onb-make-option" data-checked={choices.workStyle === style || undefined}>
              <input
                type="radio"
                name="workStyle"
                value={style}
                aria-label={strings.t(WORK_KEYS[style].title)}
                checked={choices.workStyle === style}
                onChange={() => store.call("cmux.onboarding.makeItYours.workStyle", { value: style })}
              />
              <span className="onb-make-option-text">
                <span className="onb-make-option-title">
                  {strings.t(WORK_KEYS[style].title)}
                  {style === "gui" && (
                    <span className="onb-make-badge">{strings.t("onboarding.makeItYours.recommended")}</span>
                  )}
                </span>
                <span className="onb-make-option-detail">{strings.t(WORK_KEYS[style].detail)}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>
      <fieldset className="onb-make-group onb-make-density">
        <legend className="onb-make-label">{strings.t("onboarding.makeItYours.density.label")}</legend>
        <div className="onb-make-segments">
          {choices.densities.map((density) => (
            <label
              key={density.id}
              className="onb-make-segment"
              data-checked={choices.density === density.id || undefined}
            >
              <input
                type="radio"
                name="density"
                value={density.id}
                aria-label={density.name}
                checked={choices.density === density.id}
                onChange={() => store.call("cmux.onboarding.makeItYours.density", { value: density.id })}
              />
              <span>{density.name}</span>
            </label>
          ))}
        </div>
        {choices.textSize !== null && (
          <div className="onb-make-adjust">
            <SliderRow
              id="textSize"
              label={strings.t("onboarding.makeItYours.textSize")}
              value={choices.textSize}
              min={choices.textSizeMin}
              max={choices.textSizeMax}
              step={1}
              format={points}
              onSend={(value) => store.call("cmux.onboarding.makeItYours.textSize", { value })}
            >
              {choices.textSizeSet && (
                <button
                  type="button"
                  className="onb-make-reset"
                  onClick={() => store.call("cmux.onboarding.makeItYours.textSize", { value: null })}
                >
                  {strings.t("onboarding.makeItYours.textSize.default")}
                </button>
              )}
            </SliderRow>
          </div>
        )}
      </fieldset>
      <fieldset className="onb-make-group onb-make-theme">
        <legend className="onb-make-label">{strings.t("onboarding.makeItYours.theme")}</legend>
        <div className="onb-make-tiles">
          {themes.map((theme) => {
            const label = theme.id === NONE ? strings.t("onboarding.makeItYours.theme.default") : theme.name;
            const checked = (choices.theme ?? NONE) === theme.id;
            return (
              <label key={theme.id || "default"} className="onb-make-tile" data-checked={checked || undefined}>
                <input
                  type="radio"
                  name="theme"
                  value={theme.id}
                  aria-label={label}
                  checked={checked}
                  onChange={() =>
                    store.call("cmux.onboarding.makeItYours.theme", { id: theme.id === NONE ? null : theme.id })
                  }
                />
                <span className={cx("onb-make-tile-image", "onb-make-theme-swatch", theme.id === NONE && "is-none")}>
                  {theme.id !== NONE && (
                    <>
                      <ThemeSide strip={theme.light} />
                      <ThemeSide strip={theme.dark} />
                    </>
                  )}
                </span>
                <span className="onb-make-tile-name">{label}</span>
              </label>
            );
          })}
        </div>
        <div className="onb-make-adjust">
          <ChipRow
            name="accent"
            label={strings.t("onboarding.makeItYours.accent")}
            items={choices.accents.map((accent) => ({
              id: accent,
              label: ACCENT_KEYS[accent] ? strings.t(ACCENT_KEYS[accent]) : accent,
              dot: accentDot(accent) ?? {},
            }))}
            checked={choices.accent}
            onPick={(value) => store.call("cmux.onboarding.makeItYours.accent", { value })}
          />
          <ChipRow
            name="windowStyle"
            label={strings.t("onboarding.makeItYours.windowStyle")}
            items={choices.windowStyles.map((style) => ({
              id: style,
              label: WINDOW_STYLE_KEYS[style] ? strings.t(WINDOW_STYLE_KEYS[style]) : style,
            }))}
            checked={choices.windowStyle}
            onPick={(value) => store.call("cmux.onboarding.makeItYours.windowStyle", { value })}
          />
        </div>
      </fieldset>
      <fieldset className="onb-make-group onb-make-background">
        <legend className="onb-make-label">{strings.t("onboarding.makeItYours.background.label")}</legend>
        <div className="onb-make-tiles">
          {backgrounds.map((background) => {
            const label = backgroundLabel(background.id, background.name);
            const checked = (choices.background ?? NONE) === background.id;
            return (
              <label
                key={background.id || "none"}
                className="onb-make-tile"
                data-checked={checked || undefined}
                // tooltip-allow: a picture tile, with its name beside it only in the cards look.
                title={label}
              >
                <input
                  type="radio"
                  name="background"
                  value={background.id}
                  aria-label={label}
                  checked={checked}
                  onChange={() =>
                    store.call("cmux.onboarding.makeItYours.background", {
                      id: background.id === NONE ? null : background.id,
                    })
                  }
                />
                <HostIcon
                  image={background.preview}
                  className={cx("onb-make-tile-image", background.id === NONE && "is-none")}
                />
                {look === "cards" && <span className="onb-make-tile-name">{label}</span>}
              </label>
            );
          })}
        </div>
        <div className="onb-make-adjust">
          {choices.opacity !== null && (
            <SliderRow
              id="opacity"
              label={strings.t("onboarding.makeItYours.opacity")}
              value={choices.opacity}
              min={0}
              max={1}
              step={OPACITY_STEP}
              format={percent}
              onSend={(value) => store.call("cmux.onboarding.makeItYours.opacity", { value })}
            />
          )}
          <ChipRow
            name="material"
            label={strings.t("onboarding.makeItYours.material")}
            items={choices.materials.map((material) => ({ id: material, label: strings.t(MATERIAL_KEYS[material]) }))}
            checked={choices.material}
            onPick={(value) =>
              store.call("cmux.onboarding.makeItYours.material", { value: value as MakeItYoursMaterial })
            }
          />
        </div>
      </fieldset>
    </div>
  );
}
