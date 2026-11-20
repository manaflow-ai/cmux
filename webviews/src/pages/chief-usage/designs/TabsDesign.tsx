// "Tabs" (gallery only): the tiles, then one chart at a time behind a segmented control
// (Cost | Tokens | Cache | Latency, the shared ui/Tabs segmented variant), then the table and the top list.
import { useState } from "react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "../../../ui/Tabs";
import { BandChart, Legend, LineChart, TokenChart, tokenLegend } from "../charts";
import { BreakdownTable, Section, Tiles, TopList } from "../parts";
import type { DesignProps } from "./DesignProps";

const TABS = ["cost", "tokens", "cache", "latency"] as const;
type Tab = (typeof TABS)[number];

export function TabsDesign({ summary, by, strings }: DesignProps) {
  const [tab, setTab] = useState<Tab>("cost");
  const { series, bucket } = summary;
  return (
    <>
      <Tiles summary={summary} strings={strings} />
      <section className="cu-section">
        <Tabs variant="segmented" value={tab} onValueChange={(value) => setTab(value as Tab)}>
          <TabsList aria-label={strings.t("chiefUsage.tabs.label")}>
            {TABS.map((option) => (
              <TabsTrigger key={option} value={option}>
                {strings.t(`chiefUsage.tabs.${option}`)}
              </TabsTrigger>
            ))}
          </TabsList>
          <TabsContent value={tab} className="cu-tab-panel">
            {tab === "cost" && (
              <LineChart series={series} bucket={bucket} strings={strings} measure="usd" height={200} />
            )}
            {tab === "tokens" && (
              <>
                <Legend items={tokenLegend(strings, false)} />
                <TokenChart series={series} bucket={bucket} strings={strings} withCost={false} />
              </>
            )}
            {tab === "cache" && (
              <LineChart series={series} bucket={bucket} strings={strings} measure="hit" height={200} />
            )}
            {tab === "latency" && (
              <>
                <Legend
                  items={[
                    { key: "p50", label: strings.t("chiefUsage.series.p50"), swatch: "cu-p50" },
                    { key: "p95", label: strings.t("chiefUsage.series.p95"), swatch: "cu-band" },
                  ]}
                />
                <BandChart series={series} bucket={bucket} strings={strings} height={200} />
              </>
            )}
          </TabsContent>
        </Tabs>
      </section>
      {summary.by.length > 0 && (
        <Section title={strings.t("chiefUsage.section.breakdown")}>
          <BreakdownTable summary={summary} by={by} strings={strings} />
        </Section>
      )}
      {summary.top.length > 0 && (
        <Section title={strings.t("chiefUsage.section.top")}>
          <TopList summary={summary} strings={strings} />
        </Section>
      )}
    </>
  );
}
