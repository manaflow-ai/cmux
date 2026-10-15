import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import { locales } from "../i18n/routing";
import { fallbackContentLocales } from "../i18n/locale-availability";

type Catalog = {
  pricing?: Record<string, unknown>;
  dashboard: { billing: { picker: { names: Record<string, string>; features: Record<string, string[]> } } };
};

function catalog(locale: string): Catalog {
  return JSON.parse(readFileSync(new URL(`../messages/${locale}.json`, import.meta.url), "utf8"));
}

const english = catalog("en");

describe("Team Max messages", () => {
  test("every locale names Team Max and lists four translated plan-picker lines", () => {
    expect(english.dashboard.billing.picker.features.team_max).toEqual([
      "Everything in Team, with Max machines for every member",
      "Up to 5 Cloud VMs per paid seat, sharing 80 vCPUs and 160 GB RAM per paid seat across the team",
      "24 GB / 12 vCPU, 32 GB / 16 vCPU, and up to 64 GB / 32 vCPU machines",
      "One invoice for the whole team",
    ]);
    for (const locale of locales) {
      const picker = catalog(locale).dashboard.billing.picker;
      expect(picker.names.team_max).toBe("Team Max");
      expect(picker.features.team_max).toHaveLength(4);
      if (locale === "en") continue;
      const englishLines = english.dashboard.billing.picker.features.team_max;
      picker.features.team_max.forEach((line, index) => {
        if (index === 2) return; // Machine sizes are units and numbers in most locales.
        expect(line).not.toBe(englishLines[index]);
      });
    }
  });

  test("every locale offers the Team Max resource-pool upgrade action", () => {
    const englishAction = (english as unknown as { vmErrors: { resourcePool: Record<string, string> } })
      .vmErrors.resourcePool.upgradeTeamMaxAction;
    expect(englishAction).toBe("Pause or delete a VM, or upgrade the team to Team Max.");
    for (const locale of locales) {
      const action = (catalog(locale) as unknown as { vmErrors: { resourcePool: Record<string, string> } })
        .vmErrors.resourcePool.upgradeTeamMaxAction;
      expect(action).toContain("Team Max");
      if (locale !== "en") expect(action).not.toBe(englishAction);
    }
  });

  test("every pricing catalog describes Team Max with translated, pooled-resource copy", () => {
    type TeamMax = { name: string; cta: string; featuresLead: string; features: string[] };
    const englishCard = english.pricing?.teamMax as TeamMax;
    expect(englishCard.features.at(-1)).toBe(
      "Up to 5 Cloud VMs per paid seat, sharing 80 vCPUs and 160 GB RAM per paid seat across the team",
    );
    expect(fallbackContentLocales.every((locale) => locales.includes(locale))).toBe(true);
    for (const locale of locales) {
      const teamMax = catalog(locale).pricing?.teamMax as TeamMax;
      expect(teamMax.name).toBe("Team Max");
      expect(teamMax.features).toHaveLength(englishCard.features.length);
      expect(JSON.stringify(teamMax)).not.toMatch(/per VM|VM ごと/i);
      if (locale === "en") continue;
      expect(teamMax.cta).not.toBe(englishCard.cta);
      expect(teamMax.featuresLead).not.toBe(englishCard.featuresLead);
      teamMax.features.forEach((line, index) => expect(line).not.toBe(englishCard.features[index]));
    }
  });
});
