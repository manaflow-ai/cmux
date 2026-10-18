// Chief Pet: the floating pet's own page, after ChatGPT's Mini & Pets. A preview of the pet over
// its rail with Show Pet / Hide Pet, then every character (the Chief Dock's pixel mascots) as a
// card with its name and a line about it, and None, which hides the pet. It draws the category's
// two rows (`home.chiefPetEnabled`, `home.chiefPetMascot`), so SectionView leaves them out of the
// group list; search, the palette and `cmux settings` still reach them.
import { useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";

export const CHIEF_PET_ENABLED = "home.chiefPetEnabled";
export const CHIEF_PET_MASCOT = "home.chiefPetMascot";
/** The rows this card draws in place of their group. */
export const CHIEF_PET_ROWS: ReadonlySet<string> = new Set([CHIEF_PET_ENABLED, CHIEF_PET_MASCOT]);

/** The characters in the setting's order (`HomeChiefPetSetting.mascots`), with their art. */
export const CHIEF_PET_MASCOTS: ReadonlyArray<{ id: string; art: string }> = [
  { id: "orb", art: new URL("../../../agent-session/acpmux/mascots/ChiefMascotOrb.png", import.meta.url).href },
  {
    id: "orb-spark",
    art: new URL("../../../agent-session/acpmux/mascots/ChiefMascotOrbSpark.png", import.meta.url).href,
  },
  {
    id: "orb-hood",
    art: new URL("../../../agent-session/acpmux/mascots/ChiefMascotOrbHood.png", import.meta.url).href,
  },
  { id: "machine", art: new URL("../../../agent-session/acpmux/mascots/ChiefMascotMachine.png", import.meta.url).href },
  {
    id: "machine-cyan",
    art: new URL("../../../agent-session/acpmux/mascots/ChiefMascotMachineCyan.png", import.meta.url).href,
  },
  {
    id: "machine-blue",
    art: new URL("../../../agent-session/acpmux/mascots/ChiefMascotMachineBlue.png", import.meta.url).href,
  },
  { id: "moon", art: new URL("../../../agent-session/acpmux/mascots/ChiefMascotMoon.png", import.meta.url).href },
  {
    id: "moon-blue",
    art: new URL("../../../agent-session/acpmux/mascots/ChiefMascotMoonBlue.png", import.meta.url).href,
  },
  { id: "fox", art: new URL("../../../agent-session/acpmux/mascots/ChiefMascotFox.png", import.meta.url).href },
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

export function ChiefPetCard() {
  const store = useStore();
  const { rows, readable } = useSettingsState();
  const enabled = rows.get(CHIEF_PET_ENABLED)?.value === true;
  const value = rows.get(CHIEF_PET_MASCOT)?.value;
  const mascot = CHIEF_PET_MASCOTS.find((entry) => entry.id === value) ?? CHIEF_PET_MASCOTS[0];
  const selected = enabled ? mascot.id : "none";
  const choose = (id: string) => {
    if (id === "none") return void store.set(CHIEF_PET_ENABLED, false);
    void store.set(CHIEF_PET_MASCOT, id).then(() => (enabled ? undefined : store.set(CHIEF_PET_ENABLED, true)));
  };
  return (
    <section className="group chief-pet" data-card="chief-pet" data-enabled={enabled ? "true" : "false"}>
      <div className="chief-pet-header" data-row-key={CHIEF_PET_ENABLED}>
        <p className="chief-pet-lede">{t("settingsPage.chiefPet.lede")}</p>
        <button
          type="button"
          className="button"
          data-action="chief-pet-toggle"
          disabled={!readable}
          onClick={() => void store.set(CHIEF_PET_ENABLED, !enabled)}
        >
          {enabled ? t("settingsPage.chiefPet.hide") : t("settingsPage.chiefPet.show")}
        </button>
      </div>
      <div className="chief-pet-preview" data-enabled={enabled ? "true" : "false"}>
        <img className="chief-pet-art" src={mascot.art} alt={t(`settings.choice.chiefPetMascot.${mascot.id}`)} />
        <Rail />
      </div>
      <h3 className="group-title">{t("settingsPage.chiefPet.pets")}</h3>
      <div className="chief-pet-grid" data-row-key={CHIEF_PET_MASCOT}>
        <button
          type="button"
          aria-pressed={selected === "none"}
          className="chief-pet-choice"
          data-pet="none"
          disabled={!readable}
          onClick={() => choose("none")}
        >
          <span className="chief-pet-choice-art chief-pet-none">
            <Rail />
          </span>
          <strong>{t("settingsPage.chiefPet.none")}</strong>
          <span className="chief-pet-choice-help">{t("settingsPage.chiefPet.none.help")}</span>
        </button>
        {CHIEF_PET_MASCOTS.map((entry) => (
          <button
            key={entry.id}
            type="button"
            aria-pressed={selected === entry.id}
            className="chief-pet-choice"
            data-pet={entry.id}
            disabled={!readable}
            onClick={() => choose(entry.id)}
          >
            <span className="chief-pet-choice-art">
              <img src={entry.art} alt="" />
            </span>
            <strong>{t(`settings.choice.chiefPetMascot.${entry.id}`)}</strong>
            <span className="chief-pet-choice-help">{t(`settingsPage.chiefPet.about.${entry.id}`)}</span>
          </button>
        ))}
      </div>
    </section>
  );
}
