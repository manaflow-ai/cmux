// "Small multiples" (gallery only): a 2 × 2 grid of sparkline cards (cost, tokens, cache hit,
// turn time p50), each with its own window total, then the table and the top list.
import { Sparkline } from "../charts";
import { BreakdownTable, Section, TopList } from "../parts";
import { formatMs, formatPercent, formatTokens, formatUSD, tokenTotal } from "../shape";
import type { DesignProps } from "./DesignProps";

export function SmallMultiplesDesign({ summary, by, strings }: DesignProps) {
  const { series, bucket, totals } = summary;
  const language = strings.language;
  const cards = [
    {
      key: "cost",
      label: strings.t("chiefUsage.tile.cost"),
      total: formatUSD(totals.usd, language),
      values: series.map((point) => point.usd),
      format: (value: number | null) => formatUSD(value ?? 0, language),
      swatch: "cu-cost",
    },
    {
      key: "tokens",
      label: strings.t("chiefUsage.tile.tokens"),
      total: formatTokens(tokenTotal(totals), language),
      values: series.map((point) => tokenTotal(point)),
      format: (value: number | null) => formatTokens(value ?? 0, language),
      swatch: "cu-kind-cache_read",
    },
    {
      key: "hit",
      label: strings.t("chiefUsage.tile.hit"),
      total: formatPercent(totals.hit, language),
      values: series.map((point) => point.hit),
      format: (value: number | null) => formatPercent(value, language),
      swatch: "cu-hit-line",
    },
    {
      key: "latency",
      label: strings.t("chiefUsage.section.latency"),
      total: formatMs(totals.ms_p50, language),
      values: series.map((point) => point.ms_p50),
      format: (value: number | null) => formatMs(value, language),
      swatch: "cu-p50",
    },
  ];
  return (
    <>
      <section className="cu-multiples">
        {cards.map((card) => (
          <div key={card.key} className="cu-card">
            <div className="cu-tile-label">{card.label}</div>
            <div className="cu-tile-value">{card.total}</div>
            <Sparkline
              values={card.values}
              series={series}
              bucket={bucket}
              strings={strings}
              label={card.label}
              format={card.format}
              swatch={card.swatch}
            />
          </div>
        ))}
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
