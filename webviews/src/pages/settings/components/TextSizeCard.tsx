// Settings > General's first card (David Beyer, Nov 20: Settings was overwhelming and he could not find a sidebar
// font size): one Text Size for the sidebar, tabs, menus and chat (appearance.metrics.chromeFontSize) and the density
// beside it (appearance.density), through the picker the Set Up cmux card draws too (ui/TextSizePicker). Every
// size in points and every density stays in Appearance's Density card, which this card links to.
import { useMemo } from "react";
import { Button } from "../../../ui/Button";
import { TextSizePicker, type TextSizePickerLabels } from "../../../ui/TextSizePicker";
import { DENSITY_BODY_POINTS } from "../../../ui/textSize";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import {
  CUSTOM_DENSITIES_KEY,
  CUSTOM_DENSITY_KEY,
  DEFAULT_DENSITY,
  DENSITY_KEY,
  TEXT_SIZE_KEY,
  customDensities,
  resolve,
} from "../density";
import { sectionHref } from "../router";
import { t } from "../strings";

export function textSizeLabels(): TextSizePickerLabels {
  return {
    size: t("settingsPage.textSize.size"),
    density: t("settings.appearance.density"),
    steps: {
      smaller: t("settingsPage.textSize.smaller"),
      default: t("settings.choice.default"),
      large: t("settingsPage.textSize.large"),
      larger: t("settingsPage.textSize.larger"),
      largest: t("settingsPage.textSize.largest"),
    },
    densities: {
      compact: t("settings.choice.compact"),
      cozy: t("settings.choice.default"),
      comfortable: t("settings.choice.comfortable"),
    },
  };
}

export function TextSizeCard() {
  const store = useStore();
  const router = useSettingsRouter();
  const { rows } = useSettingsState();
  const customs = useMemo(() => customDensities(rows.get(CUSTOM_DENSITIES_KEY)?.value), [rows]);
  const customID = rows.get(CUSTOM_DENSITY_KEY)?.value;
  const custom = typeof customID === "string" ? customs.find((item) => item.id === customID) : undefined;
  const density = custom?.id ?? ((rows.get(DENSITY_KEY)?.value ?? DEFAULT_DENSITY) as string);
  // The steps are whole points over the density's own body text (Swift `DensityTokens.bodySize`).
  const body = custom ? resolve(custom).body : (DENSITY_BODY_POINTS[density] ?? DENSITY_BODY_POINTS.cozy!);
  const value = rows.get(TEXT_SIZE_KEY)?.value;
  return (
    <section className="group text-size-card" data-card="textSize" aria-labelledby="text-size-card-title">
      <header className="text-size-card__head">
        <h2 className="group-title" id="text-size-card-title">
          {t("settings.appearance.textSize")}
        </h2>
        <Button
          type="button"
          variant="ghost"
          className="button text-size-card__more"
          onClick={() => router.history.push(sectionHref("appearance", "card.density"))}
        >
          {t("settingsPage.textSize.more")}
        </Button>
      </header>
      <p className="text-size-card__detail">{t("settings.appearance.textSize.help")}</p>
      <TextSizePicker
        labels={textSizeLabels()}
        value={typeof value === "number" ? value : null}
        density={density}
        body={body}
        onSize={(points) => void (points === null ? store.reset(TEXT_SIZE_KEY) : store.set(TEXT_SIZE_KEY, points))}
        onDensity={(id) => void store.set(DENSITY_KEY, id)}
      />
    </section>
  );
}
