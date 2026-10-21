// The Chief Usage page's non-chart parts every design shares: the tiles, the breakdown table and
// the list of the most expensive units.
import type { ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { formatCount, formatMs, formatPercent, formatTokens, formatUSD, formatWhen, tokenTotal } from "./shape";
import type { UsageBy, UsageGroup, UsageSummary, UsageTopUnit } from "./types";

export interface Tile {
  key: string;
  label: string;
  value: string;
}

/** Cost, tokens, cache hit, turns and turn time p50 / p95 of the whole window. */
export function tiles(summary: UsageSummary, strings: Strings): Tile[] {
  const language = strings.language;
  const totals = summary.totals;
  return [
    { key: "cost", label: strings.t("chiefUsage.tile.cost"), value: formatUSD(totals.usd, language) },
    { key: "tokens", label: strings.t("chiefUsage.tile.tokens"), value: formatTokens(tokenTotal(totals), language) },
    { key: "hit", label: strings.t("chiefUsage.tile.hit"), value: formatPercent(totals.hit, language) },
    { key: "turns", label: strings.t("chiefUsage.tile.turns"), value: formatCount(totals.turns, language) },
    {
      key: "turnTime",
      label: strings.t("chiefUsage.tile.turnTime"),
      value: `${formatMs(totals.ms_p50, language)} / ${formatMs(totals.ms_p95, language)}`,
    },
  ];
}

export function Tiles({ summary, strings }: { summary: UsageSummary; strings: Strings }) {
  return (
    <section className="cu-tiles">
      {tiles(summary, strings).map((tile) => (
        <div key={tile.key} className="cu-tile" data-tile={tile.key}>
          <div className="cu-tile-label">{tile.label}</div>
          <div className="cu-tile-value">{tile.value}</div>
        </div>
      ))}
    </section>
  );
}

/** A unit kind in the person's words. */
export const kindName = (kind: string, strings: Strings) =>
  kind === "turn" || kind === "compactor" || kind === "subagent" ? strings.t(`chiefUsage.kind.${kind}`) : kind;

/** A breakdown row's name: kinds in the person's words, units with no subagent as the Chief itself. */
export function groupName(group: UsageGroup, by: UsageBy, strings: Strings): string {
  if (by === "kind") return kindName(group.key, strings);
  if (by === "agent" && group.key === "") return strings.t("chiefUsage.by.noAgent");
  return group.label || group.key;
}

export function BreakdownTable({ summary, by, strings }: { summary: UsageSummary; by: UsageBy; strings: Strings }) {
  const language = strings.language;
  const total = Math.max(Number.EPSILON, summary.totals.usd);
  return (
    <table className="cu-table">
      <thead>
        <tr>
          <th scope="col">{strings.t(`chiefUsage.by.${by}`)}</th>
          <th scope="col" className="cu-num">
            {strings.t("chiefUsage.table.cost")}
          </th>
          <th scope="col" className="cu-num">
            {strings.t("chiefUsage.table.tokens")}
          </th>
          <th scope="col" className="cu-num">
            {strings.t("chiefUsage.table.hit")}
          </th>
          <th scope="col" className="cu-num">
            {strings.t("chiefUsage.table.turns")}
          </th>
          <th scope="col" className="cu-num">
            {strings.t("chiefUsage.table.p50")}
          </th>
        </tr>
      </thead>
      <tbody>
        {summary.by.map((group) => (
          <tr key={group.key} className="cu-row">
            <th scope="row">
              <span className="cu-row-name">{groupName(group, by, strings)}</span>
              <span className="cu-share" aria-hidden="true">
                <span style={{ width: `${Math.round((100 * group.usd) / total)}%` }} />
              </span>
            </th>
            <td className="cu-num">{formatUSD(group.usd, language)}</td>
            <td className="cu-num">{formatTokens(tokenTotal(group), language)}</td>
            <td className="cu-num">{formatPercent(group.hit, language)}</td>
            <td className="cu-num">{formatCount(group.turns, language)}</td>
            <td className="cu-num">{formatMs(group.ms_p50, language)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/** What a top unit is: `Chief turn`, `Subagent a241`, `Compactor · block 5236+4`. */
export function unitName(unit: UsageTopUnit, strings: Strings): string {
  if (unit.kind === "subagent" && unit.agent) return strings.format("chiefUsage.top.subagent", unit.agent);
  if (unit.kind === "compactor") return strings.format("chiefUsage.top.block", unit.key.replace(/^node:/, ""));
  return kindName(unit.kind, strings);
}

export function TopList({ summary, strings }: { summary: UsageSummary; strings: Strings }) {
  const language = strings.language;
  const chiefs = new Map(summary.chiefs.map((chief) => [chief.id, chief.label]));
  return (
    <ol className="cu-top">
      {summary.top.map((unit) => {
        const body = (
          <>
            <span className="cu-top-name">{unitName(unit, strings)}</span>
            <span className="cu-top-meta">
              {[
                summary.chiefs.length > 1 ? (chiefs.get(unit.chief) ?? unit.chief) : null,
                unit.model,
                formatWhen(unit.ts, language),
              ]
                .filter(Boolean)
                .join(" · ")}
            </span>
            <span className="cu-num cu-top-tokens">{formatTokens(tokenTotal(unit), language)}</span>
            <span className="cu-num cu-top-cost">{formatUSD(unit.usd, language)}</span>
          </>
        );
        return (
          <li key={`${unit.key}:${unit.ts}`}>
            {unit.link ? (
              <a className="cu-top-row" href={unit.link}>
                {body}
              </a>
            ) : (
              <div className="cu-top-row">{body}</div>
            )}
          </li>
        );
      })}
    </ol>
  );
}

/** A section with its heading. */
export function Section({ title, children, className }: { title: string; children: ReactNode; className?: string }) {
  return (
    <section className={`cu-section ${className ?? ""}`}>
      <h2 className="cu-section-title">{title}</h2>
      {children}
    </section>
  );
}
