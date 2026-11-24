import { describe, expect, mock, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { createTranslator, type AbstractIntlMessages } from "use-intl/core";

import enMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";
import {
  NEXT_INCLUDED_MACHINE_MINUTES,
  NEXT_OVERAGE_STANDARD_MACHINE_HOUR_USD,
  cloudPlanFacts,
  includedStandardMachineHours,
} from "../services/billing/cloudPlans";

// The cmux Cloud plans preview (/next/cloud): every figure from cloudPlans.ts, the price book's copy.

const catalogs = { en: enMessages, ja: jaMessages } as Record<string, unknown>;
let locale = "en";
const translator = (namespace?: string) =>
  createTranslator({
    locale,
    messages: catalogs[locale] as AbstractIntlMessages,
    namespace: namespace as never,
    timeZone: "UTC",
  });

mock.module("next/navigation", () =>
  createNextNavigationMock(() => {
    throw new Error("redirect");
  }),
);
mock.module("next-intl/server", () => ({
  getTranslations: async (options?: string | { namespace?: string }) =>
    translator(typeof options === "string" ? options : options?.namespace),
  setRequestLocale: () => undefined,
}));
mock.module("../app/[locale]/components/site-header", () => ({ SiteHeader: () => <header /> }));

const { default: NextCloudPlansPage } = await import("../app/[locale]/(landing)/next/cloud/page");

async function renderPage(lang: string) {
  locale = lang;
  return renderToString(await NextCloudPlansPage({ params: Promise.resolve({ locale: lang }) }));
}

const text = (html: string) => html.replace(/<!-- -->/g, "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

describe("cmux Cloud plans", () => {
  test("the hours are the price book's minutes on the 4 vCPU machine", () => {
    expect(includedStandardMachineHours("next_plus")).toBe(375);
    expect(includedStandardMachineHours("next_pro")).toBe(937.5);
    expect(includedStandardMachineHours("next_max")).toBe(3750);
    // Every plan is 4,500 machine minutes per dollar (Plan.ts).
    for (const plan of cloudPlanFacts()) {
      expect(NEXT_INCLUDED_MACHINE_MINUTES[plan.id] / plan.monthUsd).toBe(4500);
    }
    expect(NEXT_OVERAGE_STANDARD_MACHINE_HOUR_USD).toBe(0.08);
  });

  test("the page prints each plan's price, hours and the price after", async () => {
    const page = text(await renderPage("en"));
    for (const [name, price, hours] of [
      ["cmux NEXT Plus", "$20", "375"],
      ["cmux NEXT Pro", "$50", "937.5"],
      ["cmux NEXT Max", "$200", "3,750"],
    ]) {
      expect(page).toContain(`${name} ${price} /mo ${hours} hours of your machine a month 4 vCPUs, 16 GB memory`);
    }
    expect(page).toContain("Then $0.08 an hour");
    expect(page).toContain("Billed by the second, shown by the minute");
    expect(page).toContain("Model usage is not included.");
  });

  test("Japanese copy carries the same numbers", async () => {
    const page = text(await renderPage("ja"));
    expect(page).toContain("あなたのマシンを月 937.5 時間");
    expect(page).toContain("あなたのマシンを月 3,750 時間");
    expect(page).toContain("超えた分は 1 時間 $0.08");
  });

  test("no internal words in the copy", async () => {
    for (const lang of ["en", "ja"]) {
      const page = text(await renderPage(lang)).toLowerCase();
      for (const word of ["vm", "sandbox", "hybrid", "sync", "slot", "machine minute", "freestyle", "autocloud", "unlimited"]) {
        expect(page).not.toMatch(new RegExp(`\\b${word}\\b`));
      }
    }
  });
});
