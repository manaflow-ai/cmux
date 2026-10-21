// "Receipt" (gallery only): list first. One row per bucket, newest first, with its cost, tokens
// and cache hit as inline bars (no axes), a total line, then the top list.
import { Section, TopList } from "../parts";
import { bucketTitle, formatPercent, formatTokens, formatUSD, tokenTotal } from "../shape";
import type { DesignProps } from "./DesignProps";

function ReceiptTable({ summary, strings }: DesignProps) {
  const language = strings.language;
  const rows = [...summary.series].reverse();
  const maxUsd = Math.max(Number.EPSILON, ...rows.map((point) => point.usd));
  const maxTokens = Math.max(1, ...rows.map((point) => tokenTotal(point)));
  const bar = (share: number, swatch: string) => (
    <span className="cu-inline-track" aria-hidden="true">
      <span className={`cu-inline-bar ${swatch}`} style={{ width: `${Math.round(share * 100)}%` }} />
    </span>
  );
  return (
    <table className="cu-table cu-receipt">
      <thead>
        <tr>
          <th scope="col">{strings.t("chiefUsage.table.period")}</th>
          <th scope="col">{strings.t("chiefUsage.table.cost")}</th>
          <th scope="col">{strings.t("chiefUsage.table.tokens")}</th>
          <th scope="col">{strings.t("chiefUsage.table.hit")}</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((point) => (
          <tr key={point.t} className="cu-row">
            <th scope="row">{bucketTitle(point.t, summary.bucket, language)}</th>
            <td>
              <span className="cu-num">{formatUSD(point.usd, language)}</span>
              {bar(point.usd / maxUsd, "cu-cost")}
            </td>
            <td>
              <span className="cu-num">{formatTokens(tokenTotal(point), language)}</span>
              {bar(tokenTotal(point) / maxTokens, "cu-kind-cache_read")}
            </td>
            <td>
              <span className="cu-num">{formatPercent(point.hit, language)}</span>
              {bar(point.hit ?? 0, "cu-hit-line")}
            </td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row">{strings.t("chiefUsage.table.total")}</th>
          <td className="cu-num">{formatUSD(summary.totals.usd, language)}</td>
          <td className="cu-num">{formatTokens(tokenTotal(summary.totals), language)}</td>
          <td className="cu-num">{formatPercent(summary.totals.hit, language)}</td>
        </tr>
      </tfoot>
    </table>
  );
}

/** The receipt and, under it, the most expensive units. */
export function ReceiptDesign(props: DesignProps) {
  return (
    <>
      <ReceiptTable {...props} />
      {props.summary.top.length > 0 && (
        <Section title={props.strings.t("chiefUsage.section.top")}>
          <TopList summary={props.summary} strings={props.strings} />
        </Section>
      )}
    </>
  );
}
