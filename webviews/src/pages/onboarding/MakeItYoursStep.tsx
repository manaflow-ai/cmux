// Make cmux Yours (cmux#48416, cmux#49636): a new person's one setup screen (screen "all", what ships),
// or, behind `experiments.introWalk` (off by default), the intro walk's four screens (hq RFD 0057): 1 Pick a look
// (five whole-app look tiles, each with a light and a dark face, and the Tidy switch), 2 How you work,
// 3 Trust and noise (the agents' permission, explained per mode, and banners and sound), 4 Tune (density,
// asked only here, and the background rows below). Each opens on what the settings hold, so Return four
// times is a good setup. The look, trust and noise rows are walk.ts's writes, one publish per click.
// The rows of screens 2 and 4:
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
import { Switch } from "../../ui/Switch";
import type { MakeItYoursState, WorkStyle, MakeItYoursMaterial } from "./ops";
import { HostIcon, useOnboarding } from "./parts";
import { SlidingIndicator } from "../../ui/motion/SlidingIndicator";
import {
  LOOK_BUNDLES,
  NOISES,
  PERMISSIONS,
  bundleWrites,
  noise,
  noiseWrites,
  permission,
  permissionWrites,
  pickedBundle,
  tidyOn,
  tidyWrites,
  walkValues,
  type MakeItYoursScreen,
  type WalkValues,
  type WalkWrite,
} from "./walk";
import { Faces } from "./walkLook";

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

/** The intro walk's writes: one op, one publish. */
function useWalk() {
  const { store } = useOnboarding();
  return (writes: WalkWrite[]) => {
    if (writes.length > 0) store.call("cmux.onboarding.makeItYours.walk", { writes });
  };
}

const PERMISSION_KEYS = {
  ask: "onboarding.makeItYours.permission.ask",
  standard: "onboarding.makeItYours.permission.standard",
  fullAccess: "onboarding.makeItYours.permission.fullAccess",
} as const;
const NOISE_KEYS = {
  quiet: "onboarding.makeItYours.noise.quiet",
  banners: "onboarding.makeItYours.noise.banners",
  bannersSound: "onboarding.makeItYours.noise.bannersSound",
} as const;

/** Screen 1: the five look tiles (House, what the person has, first) and Tidy, off unless already set. */
function LookScreen({ opened, current }: { opened: WalkValues; current: WalkValues }) {
  const { strings } = useOnboarding();
  const walk = useWalk();
  const picked = pickedBundle(opened, current);
  const pickedName = LOOK_BUNDLES.find((bundle) => bundle.id === picked);
  const tidy = tidyOn(current);
  return (
    <>
      <fieldset className="onb-make-group onb-walk" data-screen="look" data-layout="grid">
        <legend className="onb-make-label">
          {strings.t("onboarding.makeItYours.look.label")}
          {pickedName && (
            <span className="onb-make-label-value" aria-hidden="true">
              {strings.t(pickedName.nameKey)}
            </span>
          )}
        </legend>
        <div className="onb-walk-looks">
          {LOOK_BUNDLES.map((bundle) => {
            const checked = bundle.id === picked;
            return (
              <label key={bundle.id} className="onb-make-option onb-walk-look" data-checked={checked || undefined}>
                <input
                  type="radio"
                  name="look"
                  value={bundle.id}
                  aria-label={strings.t(bundle.nameKey)}
                  aria-description={strings.t(bundle.lineKey)}
                  checked={checked}
                  onChange={() => walk(bundleWrites(bundle, opened, current))}
                />
                <Faces bundle={bundle} />
                <span className="onb-walk-look-text">
                  <span className="onb-walk-look-name">{strings.t(bundle.nameKey)}</span>
                  <span className="onb-walk-line">{strings.t(bundle.lineKey)}</span>
                </span>
              </label>
            );
          })}
        </div>
      </fieldset>
      <div className="onb-make-group onb-walk-tidy">
        <span className="onb-make-option-text">
          <span className="onb-make-option-title" id="onb-walk-tidy-label">
            {strings.t("onboarding.makeItYours.tidy")}
          </span>
          <span className="onb-make-option-detail">{strings.t("onboarding.makeItYours.tidy.detail")}</span>
        </span>
        <Switch
          size="sm"
          checked={tidy}
          aria-labelledby="onb-walk-tidy-label"
          onCheckedChange={(on: boolean) => walk(tidyWrites(on, opened, current))}
        />
      </div>
    </>
  );
}

/** Screen 3: how much agents may do (each mode explained; Full Access, as cmux ships, preselected on a
 * new Mac) and how loudly cmux tells you, each as radios with their line. */
function TrustScreen({ opened, current }: { opened: WalkValues; current: WalkValues }) {
  const { strings } = useOnboarding();
  const walk = useWalk();
  const mode = permission(current);
  const loud = noise(current);
  return (
    <>
      <fieldset className="onb-make-group onb-make-work" data-screen="trust">
        <legend className="onb-make-label">{strings.t("onboarding.makeItYours.permission.label")}</legend>
        <div className="onb-make-options">
          {PERMISSIONS.map((value) => (
            <label key={value} className="onb-make-option" data-checked={mode === value || undefined}>
              <input
                type="radio"
                name="permission"
                value={value}
                aria-label={strings.t(PERMISSION_KEYS[value])}
                checked={mode === value}
                onChange={() => walk(permissionWrites(value, opened, current))}
              />
              <span className="onb-make-option-text">
                <span className="onb-make-option-title">{strings.t(PERMISSION_KEYS[value])}</span>
                <span className="onb-make-option-detail">{strings.t(`${PERMISSION_KEYS[value]}.line`)}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>
      <fieldset className="onb-make-group onb-make-work">
        <legend className="onb-make-label">{strings.t("onboarding.makeItYours.noise.label")}</legend>
        <div className="onb-make-options">
          {NOISES.map((value) => (
            <label key={value} className="onb-make-option" data-checked={loud === value || undefined}>
              <input
                type="radio"
                name="noise"
                value={value}
                aria-label={strings.t(NOISE_KEYS[value])}
                checked={loud === value}
                onChange={() => walk(noiseWrites(value, opened, current))}
              />
              <span className="onb-make-option-text">
                <span className="onb-make-option-title">{strings.t(NOISE_KEYS[value])}</span>
                <span className="onb-make-option-detail">{strings.t(`${NOISE_KEYS[value]}.line`)}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>
    </>
  );
}

export function MakeItYoursStep({
  choices,
  look = DEFAULT_MAKE_IT_YOURS_LOOK,
  screen = "all",
  opened,
}: {
  choices: MakeItYoursState | null | undefined;
  look?: MakeItYoursLook;
  /** The walk's screen shown; "all": today's one screen (experiments.introWalk off). */
  screen?: MakeItYoursScreen | "all";
  /** The settings when the step opened (what House and the rows' "as before" write back); absent: now. */
  opened?: WalkValues | null;
}) {
  const { strings, store } = useOnboarding();
  if (choices == null) return null;
  const current = walkValues(choices);
  if (screen === "look" || screen === "trust") {
    const Screen = screen === "look" ? LookScreen : TrustScreen;
    return (
      <div className="onb-make" data-look={look} data-screen={screen}>
        <Screen opened={opened ?? current} current={current} />
      </div>
    );
  }
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
    <div className="onb-make" data-look={look} data-screen={screen === "all" ? undefined : screen}>
      {(screen === "all" || screen === "work") && (
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
      )}
      {(screen === "all" || screen === "tune") && (
        <>
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
        </>
      )}
    </div>
  );
}
