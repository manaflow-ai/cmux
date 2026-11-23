import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../../ui/Menu";
import { ChevronIcon } from "../ComposerPickers";
import { EnvironmentIcon } from "../EnvironmentPicker";
import { useT, type Translate } from "../i18n";
import type { PlaceMode, PlaceState } from "./placeModel";
import "./place.css";

/// How the control draws (PlaceControl.gallery.tsx compares them): `segmented`, Local, Cloud and Auto
/// side by side with the rule of Auto under it; `menu`, one chip with the choice in a menu; `rows`,
/// three stacked rows with where each runs under its name.
export type PlaceControlLook = "segmented" | "menu" | "rows";

const MODES: readonly PlaceMode[] = ["local", "cloud", "auto"];

/// The place's name: the chat's own VM when known.
export function cloudLabel(place: PlaceState, t: Translate): string {
  return place.cloudName ?? t("place.cloud");
}

export function placeName(place: PlaceState, t: Translate): string {
  return place.at === "cloud" ? cloudLabel(place, t) : t("place.thisMac");
}

/// The control's face: the choice, and for Auto where it runs now.
export function faceText(place: PlaceState, t: Translate): string {
  if (place.move?.state === "moving") return t("place.faceMoving", { to: place.move.to });
  if (place.mode === "auto") return t(place.at === "cloud" ? "place.faceAutoCloud" : "place.faceAutoLocal");
  return t(place.mode === "cloud" ? "place.faceCloud" : "place.faceLocal");
}

const modeLabel = (mode: PlaceMode, t: Translate) => t(`place.${mode}`);

function ModeIcon({ mode, place }: { mode: PlaceMode; place: PlaceState }) {
  if (mode === "local") return <EnvironmentIcon kind="local" />;
  if (mode === "cloud") return <EnvironmentIcon kind="cloud" />;
  return (
    <svg
      className="acpmux-icon acpmux-place-auto-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      data-at={place.at}
    >
      <path d="M13 8a5 5 0 0 1-8.7 3.4M3 8a5 5 0 0 1 8.7-3.4" />
      <path d="M11.8 1.8v2.8H9M4.2 14.2v-2.8H7" />
    </svg>
  );
}

/// The chat's place: where it runs (Local, Cloud) or that cmux decides (Auto). A pick runs
/// `onMode`; the app decides what it does now (Cloud moves a local chat, Local brings a Cloud one
/// back) and reports the move as `place.move`. No confirm: nothing a pick does is irreversible.
export function PlaceControl({
  place,
  look = "segmented",
  onMode,
}: {
  place: PlaceState;
  look?: PlaceControlLook;
  onMode(mode: PlaceMode): void;
}) {
  const t = useT();
  const moving = place.move?.state === "moving";
  const rule = t("placeAuto.rule");
  const here = t("place.runsAt", { place: placeName(place, t) });
  if (look === "menu") {
    return (
      <Menu>
        <MenuButton
          className="acpmux-place-chip"
          label={t("place.label")}
          title={here}
          data-menu="Place"
          aria-haspopup="menu"
        >
          <span className="acpmux-place-chip-icon">
            <ModeIcon mode={place.at === "cloud" ? "cloud" : "local"} place={place} />
          </span>
          <span className="acpmux-place-chip-text" data-moving={moving ? "true" : undefined}>
            {faceText(place, t)}
          </span>
          <ChevronIcon />
        </MenuButton>
        <MenuPopup label={t("place.label")} side="top" align="start">
          <MenuRadioGroup value={place.mode} onValueChange={(mode) => onMode(mode as PlaceMode)}>
            {MODES.map((mode) => (
              <MenuRadioItem
                key={mode}
                value={mode}
                closeOnClick
                className="acpmux-place-menu-item"
                data-value={`place-${mode}`}
              >
                <span className="acpmux-place-row-text">
                  <span>{modeLabel(mode, t)}</span>
                  {mode === "auto" && <span className="acpmux-place-rule">{rule}</span>}
                </span>
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    );
  }
  if (look === "rows") {
    return (
      <div className="acpmux-place acpmux-place-rows" role="radiogroup" aria-label={t("place.label")} title={here}>
        {MODES.map((mode) => (
          <button
            key={mode}
            type="button"
            role="radio"
            aria-checked={place.mode === mode}
            className="acpmux-place-rowbtn"
            data-testid={`place-${mode}`}
            data-on={place.mode === mode ? "true" : undefined}
            onClick={() => onMode(mode)}
          >
            <ModeIcon mode={mode} place={place} />
            <span className="acpmux-place-row-text">
              <span>{modeLabel(mode, t)}</span>
              <span className="acpmux-place-rule">
                {mode === "local"
                  ? t("place.thisMac")
                  : mode === "cloud"
                    ? (place.cloudName ?? t("place.ownVm"))
                    : rule}
              </span>
            </span>
            {place.mode === mode && <span className="acpmux-place-here" aria-hidden="true" />}
          </button>
        ))}
      </div>
    );
  }
  return (
    <div className="acpmux-place acpmux-place-seg-wrap" data-moving={moving ? "true" : undefined}>
      <div className="acpmux-place-seg" role="radiogroup" aria-label={t("place.label")} title={here}>
        {MODES.map((mode) => (
          <button
            key={mode}
            type="button"
            role="radio"
            aria-checked={place.mode === mode}
            className="acpmux-place-segbtn"
            data-testid={`place-${mode}`}
            data-on={place.mode === mode ? "true" : undefined}
            data-here={mode !== "auto" && place.at === mode ? "true" : undefined}
            onClick={() => onMode(mode)}
          >
            <ModeIcon mode={mode} place={place} />
            <span>{modeLabel(mode, t)}</span>
          </button>
        ))}
      </div>
      {place.mode === "auto" && (
        <span className="acpmux-place-rule" title={rule}>
          {rule}
        </span>
      )}
    </div>
  );
}
