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
import {
  CLOUD_COMPARE_ROWS,
  CLOUD_COMPARE_ROW_IDS,
  printableCompareRows,
  type CloudCompareRow,
} from "../services/billing/cloudCompare";

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
const { CloudCompareBlock } = await import("../app/[locale]/(landing)/next/cloud/compare-block");

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

describe("agents kept running and hours", () => {
  test("the plan table prints each plan's count beside its hours", async () => {
    const html = await renderPage("en");
    const table = text(html.match(/<table[^>]*data-testid="cloud-plan-table"[\s\S]*?<\/table>/)?.[0] ?? "");
    expect(table).toContain("cmux NEXT Plus $20 /mo 3 375");
    expect(table).toContain("cmux NEXT Pro $50 /mo 5 937.5");
    expect(table).toContain("cmux NEXT Max $200 /mo 50 3,750");
    expect(text(html)).toContain("Every hour after is $0.08.");
    expect(text(await renderPage("ja"))).toContain("超えた分は 1 時間 $0.08 です。");
  });
});

describe("the comparison block prints only measured rows", () => {
  test("today: agents at once and the unused month, in that order", async () => {
    expect(printableCompareRows().map((row) => row.id)).toEqual(["agentsAtOnce", "unusedMonth"]);
    const html = await renderPage("en");
    expect(html).toContain('data-testid="cloud-compare-agentsAtOnce"');
    expect(html).toContain('data-testid="cloud-compare-unusedMonth"');
    for (const id of CLOUD_COMPARE_ROW_IDS.filter((id) => !["agentsAtOnce", "unusedMonth"].includes(id))) {
      expect(html).not.toContain(`cloud-compare-${id}`);
    }
    const page = text(html);
    expect(page).toContain("Close your laptop. Your agents keep working.");
    expect(page).toContain("10 started together, all ready within 20 seconds");
  });

  test("a row with no proof cannot print, even with copy", () => {
    locale = "en";
    const t = translator("nextCloudPlans");
    const unproven: CloudCompareRow[] = CLOUD_COMPARE_ROWS.map((row) => ({ ...row, proof: null }));
    expect(renderToString(<CloudCompareBlock t={t} rows={unproven} />)).toBe("");
    const one: CloudCompareRow[] = [
      { id: "unusedMonth", proof: null },
      { id: "agentsAtOnce", proof: { source: "test" }, values: { machines: 10, seconds: 20 } },
    ];
    const html = renderToString(<CloudCompareBlock t={t} rows={one} />);
    expect(html).toContain("cloud-compare-agentsAtOnce");
    expect(html).not.toContain("cloud-compare-unusedMonth");
  });

  test("every proven row has its copy in English and Japanese", () => {
    type Catalog = { nextCloudPlans: { compare: { rows: Record<string, Record<string, unknown> | undefined> } } };
    for (const catalog of [enMessages, jaMessages] as unknown as Catalog[]) {
      const rows = catalog.nextCloudPlans.compare.rows;
      for (const row of printableCompareRows()) {
        for (const key of ["label", "server", "planTab", "cmux"]) expect(typeof rows[row.id]?.[key]).toBe("string");
      }
    }
  });

  test("never the forbidden claims", async () => {
    for (const lang of ["en", "ja"]) {
      const page = text(await renderPage(lang)).toLowerCase();
      for (const claim of ["cheaper than", "unlimited", "per vcpu", "per dollar"]) expect(page).not.toContain(claim);
    }
  });
});
