// Settings > Chief > Look: how the Chief looks, one glass card. The floating pet after ChatGPT's
// Mini & Pets, then the chat's Bubble Style (`home.chiefBubbleStyle`, which before stood alone below
// as a one-row "Chief Chat" card). A preview of the pet over
// its rail with Show Pet / Hide Pet, then every character (the Chief Dock's pixel mascots) as a
// card with its name and a line about it. The character is the Chief's avatar on every Chief
// surface (Home, the sidebar, message cards) whether or not the pet floats, so the chosen one is
// always checked, and a click swaps it everywhere without showing or hiding the pet (that is Show
// Pet / Hide Pet's job). Hovering or focusing a character previews it on the rail. It draws the category's
// three rows (`home.chiefPetEnabled`, `home.chiefPetMascot`, `home.chiefBubbleStyle`), so SectionView
// leaves them out of the group list; search, the palette and `cmux settings` still reach them.
import { useRef, useState } from "react";
import { useRowState, useStore, type RowState } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";
import { rowsByKey } from "../schema";
import { RowStatus, SettingRow } from "./SettingRow";
import mascotOrb from "../../../agent-session/acpmux/mascots/ChiefMascotOrb.png";
import mascotOrbSpark from "../../../agent-session/acpmux/mascots/ChiefMascotOrbSpark.png";
import mascotOrbHood from "../../../agent-session/acpmux/mascots/ChiefMascotOrbHood.png";
import mascotMachine from "../../../agent-session/acpmux/mascots/ChiefMascotMachine.png";
import mascotMachineCyan from "../../../agent-session/acpmux/mascots/ChiefMascotMachineCyan.png";
import mascotMachineBlue from "../../../agent-session/acpmux/mascots/ChiefMascotMachineBlue.png";
import mascotMoon from "../../../agent-session/acpmux/mascots/ChiefMascotMoon.png";
import mascotMoonBlue from "../../../agent-session/acpmux/mascots/ChiefMascotMoonBlue.png";
import mascotFox from "../../../agent-session/acpmux/mascots/ChiefMascotFox.png";
import mascotMochi from "../../../agent-session/acpmux/mascots/ChiefMascotMochi.png";

export const CHIEF_PET_ENABLED = "home.chiefPetEnabled";
export const CHIEF_PET_MASCOT = "home.chiefPetMascot";
export const CHIEF_BUBBLE_STYLE = "home.chiefBubbleStyle";
/** The rows this card draws in place of their group. */
export const CHIEF_PET_ROWS: ReadonlySet<string> = new Set([CHIEF_PET_ENABLED, CHIEF_PET_MASCOT, CHIEF_BUBBLE_STYLE]);

/** The characters in the setting's order (`HomeChiefPetSetting.mascots`), with their art. Imported,
 * not `new URL(..., import.meta.url)`: the shipped page is one self-contained index.html whose CSP
 * allows `img-src data:` only, so its bundler (bundle.mjs) inlines each PNG as a data URL. */
export const CHIEF_PET_MASCOTS: ReadonlyArray<{ id: string; art: string }> = [
  { id: "orb", art: mascotOrb },
  { id: "orb-spark", art: mascotOrbSpark },
  { id: "orb-hood", art: mascotOrbHood },
  { id: "machine", art: mascotMachine },
  { id: "machine-cyan", art: mascotMachineCyan },
  { id: "machine-blue", art: mascotMachineBlue },
  { id: "moon", art: mascotMoon },
  { id: "moon-blue", art: mascotMoonBlue },
  { id: "fox", art: mascotFox },
  { id: "mochi", art: mascotMochi },
];

/** The rail under the pet, as the pet draws it: compose and the chevron. */
function Rail() {
  return (
    <span className="chief-pet-rail" aria-hidden="true">
      <Icon name="square.and.pencil" />
      <i />
      <Icon name="chevron" className="chief-pet-up" />
    </span>
  );
}

export function ChiefPetCard({
  focus = null,
  query = "",
  visibleRows = null,
}: {
  focus?: string | null;
  query?: string;
  /** Search results pass the matching Look rows; the normal page shows the whole card. */
  visibleRows?: ReadonlySet<string> | null;
}) {
  const store = useStore();
  const shown = useRowState(CHIEF_PET_ENABLED);
  const character = useRowState(CHIEF_PET_MASCOT);
  // A search result (`?focus=`) lands on its control (Show/Hide, or the selected choice) once per
  // focus, after the values arrive (as SettingRow): a later click that moves the selection keeps focus.
  const revealedFor = useRef<string | null>(null);
  // The character under the pointer or keyboard focus: the preview shows it until it leaves.
  const [previewed, setPreviewed] = useState<string | null>(null);
  const target = shown.connected && shown.readable && character.readable ? focus : null;
  const reveal = (control: HTMLElement | null) => {
    if (!control || revealedFor.current === target) return;
    revealedFor.current = target;
    control.scrollIntoView?.({ block: "center" });
    control.focus();
  };
  // As SettingRow: no writes before the owner's values arrive, while disconnected, or to a managed key.
  const locked = (state: RowState) => !state.connected || !state.readable || state.managed !== null;
  const toggleLocked = locked(shown);
  const gridLocked = locked(character);
  const enabled = shown.value === true;
  const value = character.value;
  const mascot = CHIEF_PET_MASCOTS.find((entry) => entry.id === value) ?? CHIEF_PET_MASCOTS[0];
  // A locked grid previews nothing: a disabled card may never get its mouseleave or blur.
  const live = gridLocked ? null : previewed;
  const preview = CHIEF_PET_MASCOTS.find((entry) => entry.id === live) ?? mascot;
  const bubbles = rowsByKey.get(CHIEF_BUBBLE_STYLE);
  const showPetToggle = visibleRows === null || visibleRows.has(CHIEF_PET_ENABLED);
  const showMascot = visibleRows === null || visibleRows.has(CHIEF_PET_MASCOT);
  const showBubbleStyle = visibleRows === null || visibleRows.has(CHIEF_BUBBLE_STYLE);
  return (
    <section className="group chief-pet ui-glass" data-card="chief-pet" data-enabled={enabled ? "true" : "false"}>
      <h3 className="group-title">{t("settingsPage.chief.look")}</h3>
      {showPetToggle && (
        <>
          <div className="chief-pet-header" data-row-key={CHIEF_PET_ENABLED} tabIndex={-1}>
            <p className="chief-pet-lede">{t("settingsPage.chiefPet.lede")}</p>
            <button
              type="button"
              className="button"
              data-action="chief-pet-toggle"
              role="switch"
              aria-checked={enabled}
              disabled={toggleLocked}
              ref={target === CHIEF_PET_ENABLED ? reveal : undefined}
              onClick={() => void store.set(CHIEF_PET_ENABLED, !enabled)}
            >
              {enabled ? t("settingsPage.chiefPet.hide") : t("settingsPage.chiefPet.show")}
            </button>
          </div>
          <RowStatus settingKey={CHIEF_PET_ENABLED} state={shown} />
        </>
      )}
      {showMascot && (
        <>
          <div
            className="chief-pet-preview"
            data-enabled={enabled || live ? "true" : "false"}
            data-previewing={live ? "true" : "false"}
          >
            <img className="chief-pet-art" src={preview.art} alt={t(`settings.choice.chiefPetMascot.${preview.id}`)} />
            <Rail />
          </div>
          <h3 className="group-title">{t("settingsPage.chiefPet.pets")}</h3>
          <RowStatus settingKey={CHIEF_PET_MASCOT} state={character} />
          <div className="chief-pet-grid" data-row-key={CHIEF_PET_MASCOT} tabIndex={-1}>
            {CHIEF_PET_MASCOTS.map((entry) => (
              <button
                key={entry.id}
                type="button"
                aria-pressed={mascot.id === entry.id}
                className="chief-pet-choice"
                data-pet={entry.id}
                disabled={gridLocked}
                ref={target === CHIEF_PET_MASCOT && mascot.id === entry.id ? reveal : undefined}
                onClick={() => void store.set(CHIEF_PET_MASCOT, entry.id)}
                onMouseEnter={() => setPreviewed(entry.id)}
                onMouseLeave={() => setPreviewed((id) => (id === entry.id ? null : id))}
                onFocus={() => setPreviewed(entry.id)}
                onBlur={() => setPreviewed((id) => (id === entry.id ? null : id))}
              >
                <span className="chief-pet-choice-art">
                  <img src={entry.art} alt="" />
                </span>
                <strong>{t(`settings.choice.chiefPetMascot.${entry.id}`)}</strong>
                <span className="chief-pet-choice-help">{t(`settingsPage.chiefPet.about.${entry.id}`)}</span>
              </button>
            ))}
          </div>
        </>
      )}
      {bubbles && showBubbleStyle && (
        <div className="rows">
          <SettingRow row={bubbles} query={query} focused={focus === CHIEF_BUBBLE_STYLE} />
        </div>
      )}
    </section>
  );
}
