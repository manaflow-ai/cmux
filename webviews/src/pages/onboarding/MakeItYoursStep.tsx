// Make cmux Yours (cmux#48416): a new person's one setup screen, three choices, each already on the
// recommended answer so Continue alone is a good setup:
//   1. How you work: Agents first (recommended; Cmd-T opens the New Tab page, where a chat starts) or
//      Terminal first (Cmd-T opens a terminal). The words never say "classic".
//   2. Density: Compact, Standard or Comfortable (Settings has the two extremes).
//   3. Background: None, Shuffle Paintings or one of a few built-in works.
// No theme row: windows follow macOS's light or dark mode, and the terminal theme stays in Settings.
// Each choice is a group of native radios (the browser owns roles, arrows and focus); a pick is sent
// at once and the host writes it, so the app behind the window changes while the person watches.
// Return presses Continue, Escape skips (the page's own key handler).
import { cx } from "../../ui/cx";
import type { DensityChoice, MakeItYoursState, WorkStyle } from "./ops";
import { HostIcon, useOnboarding } from "./parts";

/** The two looks of the screen (the gallery's variant switch): `cards` ships. */
export type MakeItYoursLook = "cards" | "rows";
export const DEFAULT_MAKE_IT_YOURS_LOOK: MakeItYoursLook = "cards";

const WORK_STYLES: readonly WorkStyle[] = ["gui", "terminal"];
const WORK_KEYS: Record<WorkStyle, { title: string; detail: string }> = {
  gui: { title: "onboarding.makeItYours.work.gui", detail: "onboarding.makeItYours.work.gui.detail" },
  terminal: { title: "onboarding.makeItYours.work.terminal", detail: "onboarding.makeItYours.work.terminal.detail" },
};
const DENSITIES: readonly DensityChoice[] = ["compact", "standard", "comfortable"];
const DENSITY_KEYS: Record<DensityChoice, string> = {
  compact: "onboarding.makeItYours.density.compact",
  standard: "onboarding.makeItYours.density.standard",
  comfortable: "onboarding.makeItYours.density.comfortable",
};

/** The value a radio carries for no background (an input's value is a string). */
const NO_BACKGROUND = "";

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
          {DENSITIES.map((density) => (
            <label key={density} className="onb-make-segment" data-checked={choices.density === density || undefined}>
              <input
                type="radio"
                name="density"
                value={density}
                aria-label={strings.t(DENSITY_KEYS[density])}
                checked={choices.density === density}
                onChange={() => store.call("cmux.onboarding.makeItYours.density", { value: density })}
              />
              <span>{strings.t(DENSITY_KEYS[density])}</span>
            </label>
          ))}
        </div>
      </fieldset>
      <fieldset className="onb-make-group onb-make-background">
        <legend className="onb-make-label">{strings.t("onboarding.makeItYours.background.label")}</legend>
        <div className="onb-make-tiles">
          {backgrounds.map((background) => {
            const label = backgroundLabel(background.id, background.name);
            const checked = (choices.background ?? NO_BACKGROUND) === background.id;
            return (
              <label
                key={background.id || "none"}
                className="onb-make-tile"
                data-checked={checked || undefined}
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
                {look === "cards" && <span className="onb-make-tile-name">{label}</span>}
              </label>
            );
          })}
        </div>
      </fieldset>
    </div>
  );
}
