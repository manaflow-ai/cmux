// Make cmux Yours (cmux#48416, cmux#49636): a new person's one setup screen, each choice already on the
// recommended answer so Continue alone is a good setup:
//   1. How you work: Agents first (recommended; Cmd-T opens the New Tab page, where a chat starts) or
//      Terminal first (Cmd-T opens a terminal). The words never say "classic".
//   2. Density: every density Settings has, by Settings' names (the host sends them).
//   3. Background: None, Shuffle Paintings or one of a few calm built-in works, then the two rows
//      Settings > Appearance draws under its own picker: Opacity (how much of the theme color covers
//      the picture) and Material (None, Frosted, Glass, Clear Glass). With no picture they stay in
//      place, dimmed and inert, so picking one never moves the window's layout.
// Density and Material are segmented tracks whose selection plate slides (ui/motion/SlidingIndicator);
// the tiles show only the paintings, and the legend names the one picked (no truncated names).
// No theme row: windows follow macOS's light or dark mode, and the terminal theme stays in Settings.
// Each choice is a group of native radios (the browser owns roles, arrows and focus); a pick is sent
// at once and the host writes it, so the app behind the window changes while the person watches.
// Continue keeps the picks; Skip (and Escape) puts back what was set when the window opened.
// Return presses Continue, Escape skips (the page's own key handler).
import { useRef, useState, type CSSProperties } from "react";
import { cx } from "../../ui/cx";
import type { MakeItYoursState, WorkStyle, MakeItYoursMaterial } from "./ops";
import { HostIcon, useOnboarding } from "./parts";
import { SlidingIndicator } from "../../ui/motion/SlidingIndicator";

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

/** The value a radio carries for no background (an input's value is a string). */
const NO_BACKGROUND = "";
/** The Opacity slider's step, as Settings' row. */
const OPACITY_STEP = 0.05;

const percent = (value: number) => `${Math.round(value * 100)}%`;

/** Opacity, as Settings' row: a drag previews in the slider and is written once on release (the host
 * takes one write per click or key); an arrow key writes its step at once. A value sent shows until the
 * host's state answers it, so the thumb never jumps back and two quick keys step twice. */
function OpacitySlider({ value, label, disabled }: { value: number; label: string; disabled: boolean }) {
  const { store } = useOnboarding();
  const [drag, setDrag] = useState<number | null>(null);
  // The value sent while the host still shows `base`.
  const [sent, setSent] = useState<{ value: number; base: number } | null>(null);
  const dragging = useRef(false);
  const pending = useRef<number | null>(null);
  const current = sent !== null && sent.base === value ? sent.value : value;
  const send = (next: number) => {
    if (next === current) return;
    setSent({ value: next, base: value });
    store.call("cmux.onboarding.makeItYours.opacity", { value: next });
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
  return (
    <div className="onb-make-adjust-row">
      <span className="onb-make-adjust-label" id="onb-make-opacity-label">
        {label}
      </span>
      <span className="onb-make-slider-cell">
        <input
          type="range"
          className="onb-make-slider"
          min={0}
          max={1}
          step={OPACITY_STEP}
          value={shown}
          aria-labelledby="onb-make-opacity-label"
          aria-valuetext={percent(shown)}
          disabled={disabled}
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
            // A key (or an assistive app's step): its own gesture, written now.
            send(next);
          }}
          onPointerUp={release}
          onPointerCancel={release}
          onLostPointerCapture={release}
          onBlur={release}
        />
        <span className="onb-make-adjust-value" aria-hidden="true">
          {percent(shown)}
        </span>
      </span>
    </div>
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
  const backgrounds = [{ id: NO_BACKGROUND, name: "", preview: null }, ...choices.backgrounds];
  const backgroundLabel = (id: string, name: string) =>
    id === NO_BACKGROUND
      ? strings.t("onboarding.makeItYours.background.none")
      : id === "daily"
        ? strings.t("onboarding.makeItYours.background.shuffle")
        : name;
  const pickedId = choices.background ?? NO_BACKGROUND;
  const picked = backgroundLabel(pickedId, backgrounds.find((background) => background.id === pickedId)?.name ?? "");
  // Opacity and Material only change a picture: with None they stay in place, dimmed and inert.
  const noPicture = pickedId === NO_BACKGROUND;
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
        <div
          className="onb-make-segments ui-slide-host"
          style={{ "--onb-make-count": choices.densities.length } as CSSProperties}
        >
          <SlidingIndicator selected={choices.density} selector="[data-checked]" className="onb-make-thumb" />
          {choices.densities.map((density) => (
            <label
              key={density.id}
              className="onb-make-segment ui-slide-item"
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
      </fieldset>
      <fieldset className="onb-make-group onb-make-background">
        <legend className="onb-make-label">
          {strings.t("onboarding.makeItYours.background.label")}
          <span className="onb-make-label-value" aria-hidden="true">
            {picked}
          </span>
        </legend>
        <div className="onb-make-tiles">
          {backgrounds.map((background) => {
            const label = backgroundLabel(background.id, background.name);
            const checked = (choices.background ?? NO_BACKGROUND) === background.id;
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
                      id: background.id === NO_BACKGROUND ? null : background.id,
                    })
                  }
                />
                <HostIcon
                  image={background.preview}
                  className={cx("onb-make-tile-image", background.id === NO_BACKGROUND && "is-none")}
                />
                {look === "cards" && (
                  <span className="onb-make-tile-name" aria-hidden="true">
                    {label}
                  </span>
                )}
              </label>
            );
          })}
        </div>
        <div className="onb-make-adjust" data-off={noPicture || undefined}>
          {choices.opacity !== null && (
            <OpacitySlider
              value={choices.opacity}
              label={strings.t("onboarding.makeItYours.opacity")}
              disabled={noPicture}
            />
          )}
          <div className="onb-make-adjust-row" role="radiogroup" aria-labelledby="onb-make-material-label">
            <span className="onb-make-adjust-label" id="onb-make-material-label">
              {strings.t("onboarding.makeItYours.material")}
            </span>
            <div className="onb-make-chips ui-slide-host">
              <SlidingIndicator selected={choices.material} selector="[data-checked]" className="onb-make-thumb" />
              {choices.materials.map((material) => (
                <label
                  key={material}
                  className="onb-make-chip ui-slide-item"
                  data-checked={choices.material === material || undefined}
                >
                  <input
                    type="radio"
                    name="material"
                    value={material}
                    aria-label={strings.t(MATERIAL_KEYS[material])}
                    checked={choices.material === material}
                    disabled={noPicture}
                    onChange={() => store.call("cmux.onboarding.makeItYours.material", { value: material })}
                  />
                  <span>{strings.t(MATERIAL_KEYS[material])}</span>
                </label>
              ))}
            </div>
          </div>
        </div>
      </fieldset>
    </div>
  );
}
