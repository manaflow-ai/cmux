// l10n-allow-file: gallery fixtures, not shipped UI.
// The Chief Usage page (cmux-page://cmux.chief-usage/): the same ChiefUsagePage main.tsx mounts,
// over the mock `cmux.chief_usage.summary` provider instead of the host bridge, in each of the
// four designs (plans/cmux-next/chief-usage-analytics-DESIGN.md section 5). Ledger ships.
import { useEffect, useState, type ComponentType } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import { ChiefUsagePage } from "./ChiefUsagePage";
import type { DesignProps } from "./designs/DesignProps";
import { LedgerDesign } from "./designs/LedgerDesign";
import { ReceiptDesign } from "./designs/ReceiptDesign";
import { SmallMultiplesDesign } from "./designs/SmallMultiplesDesign";
import { TabsDesign } from "./designs/TabsDesign";
import table from "./generated/strings.json";
import { MockChiefUsageProvider, type MockUsageKind } from "./mockProvider";
import { ChiefUsageStore } from "./store";
import type { UsageWindow } from "./types";

type Design = "ledger" | "tabs" | "multiples" | "receipt";

const DESIGNS: Record<Design, ComponentType<DesignProps>> = {
  ledger: LedgerDesign,
  tabs: TabsDesign,
  multiples: SmallMultiplesDesign,
  receipt: ReceiptDesign,
};

type Props = {
  design?: Design;
  kind?: MockUsageKind;
  window?: UsageWindow;
  failure?: { code: string; message: string };
};

function ChiefUsageGallery({ design = "ledger", kind = "busy", window = "30d", failure }: Props) {
  const [store] = useState(() => new ChiefUsageStore(new MockChiefUsageProvider(kind, failure), { window }));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.setWindow(window);
  }, [store, window]);
  return <ChiefUsagePage store={store} strings={strings} design={DESIGNS[design]} />;
}

export default componentEntry<Props>({
  id: "pages.chief-usage",
  title: "Chief Usage",
  area: "Pages",
  experimental: true,
  height: 1180,
  widths: { narrow: 380, normal: 680, wide: 960 },
  covers: [
    "page:cmux.chief-usage",
    "pages/chief-usage/ChiefUsagePage.tsx",
    "pages/chief-usage/charts.tsx",
    "pages/chief-usage/parts.tsx",
    "pages/chief-usage/designs/LedgerDesign.tsx",
    "pages/chief-usage/designs/TabsDesign.tsx",
    "pages/chief-usage/designs/SmallMultiplesDesign.tsx",
    "pages/chief-usage/designs/ReceiptDesign.tsx",
  ],
  keywords: ["cost", "tokens", "cache", "usage", "chief", "analytics"],
  load: async () => ChiefUsageGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    ledger: {
      note: "Recommended. Ledger: tiles, tokens by kind with the cost line, cache hit and turn time, table and top list on one scroll. 30 days; the cache fix on Oct 19 shows as the hit jump.",
      props: {},
    },
    tabs: { note: "Tabs: one chart at a time behind Cost | Tokens | Cache | Latency.", props: { design: "tabs" } },
    multiples: {
      note: "Small multiples: a 2×2 grid of sparkline cards, each with its own total.",
      props: { design: "multiples" },
    },
    receipt: {
      note: "Receipt: one row per bucket with cost, tokens and hit as inline bars; no axes.",
      props: { design: "receipt", window: "7d" },
    },
    day: { note: "Ledger over the last 24 hours: hourly buckets.", props: { window: "24h" } },
    year: { note: "Ledger over a year: weekly buckets, only the last weeks have a ledger.", props: { window: "1y" } },
    empty: { note: "No Chief usage in the window yet.", props: { kind: "empty" } },
    failed: {
      note: "The usage tool failed; the page words it, never the tool.",
      props: { failure: { code: "cmux.chief_usage.failed", message: "usage: No such file or directory (os error 2)" } },
    },
    unavailable: {
      note: "The app could not run the usage tool; its own message is already localized.",
      props: {
        failure: {
          code: "cmux.chief_usage.unavailable",
          message: "The Chief usage tool is not bundled in this build.",
        },
      },
    },
  },
});
