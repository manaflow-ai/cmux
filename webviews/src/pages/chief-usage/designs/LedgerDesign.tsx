// "Ledger" (Recommended, ships): the tiles, one stacked-bar chart of tokens by kind with the cost
// line, a small cache-hit line and a p50 / p95 turn-time band side by side under it, then the
// breakdown table and the most expensive units. Dense, everything on one scroll.
import { BandChart, Legend, LineChart, TokenChart, tokenLegend } from "../charts";
import { BreakdownTable, Section, Tiles, TopList } from "../parts";
import type { DesignProps } from "./DesignProps";

export function LedgerDesign({ summary, by, strings }: DesignProps) {
  const { series, bucket } = summary;
  return (
    <>
      <Tiles summary={summary} strings={strings} />
      <Section title={strings.t("chiefUsage.section.tokens")}>
        <Legend items={tokenLegend(strings, true)} />
        <TokenChart series={series} bucket={bucket} strings={strings} />
      </Section>
      <div className="cu-pair">
        <Section title={strings.t("chiefUsage.section.hit")}>
          <LineChart series={series} bucket={bucket} strings={strings} measure="hit" />
        </Section>
        <Section title={strings.t("chiefUsage.section.latency")}>
          <Legend
            items={[
              { key: "p50", label: strings.t("chiefUsage.series.p50"), swatch: "cu-p50" },
              { key: "p95", label: strings.t("chiefUsage.series.p95"), swatch: "cu-band" },
            ]}
          />
          <BandChart series={series} bucket={bucket} strings={strings} />
        </Section>
      </div>
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
