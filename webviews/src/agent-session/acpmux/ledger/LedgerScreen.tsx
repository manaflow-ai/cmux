// Costs (History > Costs): what agents spent on this machine, from `_acpmux/ledger`
// (ledgerModel.ts). A totals strip, a range and a group-by, then one row per session or group,
// most expensive first, each with a bar for its share and a mark for where its cost came from.
// A session row opens its chat. The price table's version sits small under the strip. History keeps
// the range, the grouping and the last answer while another tab shows (`LedgerCache`), so a return
// paints them at once while the range reads again.
//
// Tokens in is what the agent sent that was not a cache read: uncached input plus cache writes.
// Cache reads are the same context sent again at a tenth of the price; counted in, a long chat's
// input reads as many times what it is. Cache reads, cache writes and the cache hit rate (the
// share of prompt tokens the cache served, as Session Info's) show beside it.
//
// Export saves the range and grouping as CSV or JSON (ledgerModel.ts `ledgerCsv`, `ledgerJson`):
// every row, read again at acpmux's most sessions when the page shows only the top ones.
import React, { memo, useCallback, useEffect, useRef, useState } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { Select } from "../../../ui/Select";
import { Tabs, TabsList, TabsTrigger } from "../../../ui/Tabs";
import { VirtualList } from "../../../ui/VirtualList";
import { currentLanguage, useT, type Translate } from "../i18n";
import {
  cacheHitRate,
  formatCost,
  formatCount,
  formatDuration,
  groupLabel,
  LEDGER_EXPORT_LIMIT,
  LEDGER_GROUPS,
  LEDGER_RANGES,
  ledgerCsv,
  ledgerFileName,
  ledgerJson,
  ledgerLines,
  ledgerParams,
  readLedger,
  tokensIn,
  type CostSource,
  type LedgerExportKind,
  type LedgerGroup,
  type LedgerLine,
  type LedgerRange,
  type LedgerReply,
  type LedgerTotals,
} from "./ledgerModel";
import { isOlderDaemon } from "../queue/queueModel";
import { UNKNOWN, usageShare } from "../usageStats";
import "./ledger.css";

/// How rows read (gallery `agent-pane.costs`): `bars` a label over a share bar with the cost at the
/// end (shipped), `table` a column per measure, `stacked` the bar beneath a two-line label.
export type LedgerLook = "bars" | "table" | "stacked";

type LedgerState =
  | { phase: "loading"; reply?: LedgerReply }
  | { phase: "ready"; reply: LedgerReply }
  | { phase: "older" }
  | { phase: "failed"; reply?: LedgerReply };

const ROW_HEIGHT: Record<LedgerLook, number> = { bars: 52, table: 36, stacked: 60 };

/// Tokens in: uncached input plus cache writes, never cache reads.
type LedgerView = { range: LedgerRange; group: LedgerGroup; reply?: LedgerReply };

/// What Costs last showed, kept by History (newtab/HistoryScreen.tsx) while another tab shows.
export type LedgerCache = { view(): LedgerView | undefined; keep(view: LedgerView): void };

export function createLedgerCache(): LedgerCache {
  let view: LedgerView | undefined;
  return {
    view: () => view,
    keep: (next) => {
      view = next;
    },
  };
}

/// What the note line says after an export.
type ExportWord = "saved" | "copied" | "failed";

/// How an export ended: the file was saved, the host could not save it so it went to the
/// clipboard, or the person dismissed the save panel.
export type LedgerSaveOutcome = "saved" | "copied" | "cancelled";

type Props = {
  /// `_acpmux/ledger` with `params` (direct.ts `ledger`).
  load(params: Record<string, unknown>): Promise<unknown>;
  /// Shows a session's chat.
  openSession(sessionId: string): void;
  /// Saves an export (queue/historyPages.ts: the host's save panel, else the clipboard); rejects
  /// when neither took it. Unset: no Export.
  save?(text: string, suggestedName: string, kind: LedgerExportKind): Promise<LedgerSaveOutcome>;
  /// The Export menu starts open (the gallery).
  initialExportOpen?: boolean;
  look?: LedgerLook;
  initialRange?: LedgerRange;
  initialGroup?: LedgerGroup;
  now?: number;
  cache?: LedgerCache;
};

export function LedgerScreen({
  load,
  openSession,
  save,
  initialExportOpen,
  look = "bars",
  initialRange = "7d",
  initialGroup = "session",
  now,
  cache,
}: Props) {
  const t = useT();
  const locale = currentLanguage();
  const [range, setRange] = useState<LedgerRange>(() => cache?.view()?.range ?? initialRange);
  const [group, setGroup] = useState<LedgerGroup>(() => cache?.view()?.group ?? initialGroup);
  const [state, setState] = useState<LedgerState>(() => {
    const kept = cache?.view()?.reply;
    return kept ? { phase: "loading", reply: kept } : { phase: "loading" };
  });
  const request = useRef(0);
  const loadRef = useRef(load);
  loadRef.current = load;
  // How the last export ended, for the range and grouping it wrote.
  const [lastExport, setLastExport] = useState<{ range: LedgerRange; group: LedgerGroup; outcome: ExportWord }>();

  const read = useCallback(
    (which: LedgerRange) => {
      const id = ++request.current;
      // The last answer stays on screen while the next range loads.
      setState((previous) => ({
        phase: "loading",
        ...("reply" in previous && previous.reply ? { reply: previous.reply } : {}),
      }));
      loadRef.current(ledgerParams(which, now ?? Date.now())).then(
        (value) => {
          if (id === request.current) setState({ phase: "ready", reply: readLedger(value) });
        },
        (error: unknown) => {
          if (id !== request.current) return;
          // A failed read keeps the rows it had, and the status line says the read failed.
          setState((previous) =>
            isOlderDaemon(error)
              ? { phase: "older" }
              : { phase: "failed", ...("reply" in previous && previous.reply ? { reply: previous.reply } : {}) },
          );
        },
      );
    },
    [now],
  );

  useEffect(() => {
    read(range);
    const requests = request;
    return () => {
      // A reply after the page left is dropped.
      requests.current++;
    };
  }, [range, read]);

  const reply = "reply" in state ? state.reply : undefined;
  useEffect(() => {
    cache?.keep({ range, group, ...(reply ? { reply } : {}) });
  }, [cache, range, group, reply]);
  // A new range or grouping is a new file: the last export's word shows only for its own.
  const exported = lastExport?.range === range && lastExport.group === group ? lastExport.outcome : undefined;

  const runExport = async (kind: LedgerExportKind) => {
    if (!reply || !save) return;
    const done = (outcome: ExportWord | undefined) =>
      setLastExport(outcome ? { range, group, outcome } : undefined);
    try {
      // The page holds the top sessions only: the file reads them all, for the same range.
      const data =
        group === "session" && reply.totals.sessions > reply.rows.length
          ? readLedger(
              await loadRef.current(ledgerParams(range, reply.range.until ?? now ?? Date.now(), LEDGER_EXPORT_LIMIT)),
            )
          : reply;
      const text = kind === "csv" ? ledgerCsv(data, group) : ledgerJson(data, range, group);
      const outcome = await save(text, ledgerFileName(data, range, group), kind);
      done(outcome === "cancelled" ? undefined : outcome);
    } catch {
      done("failed");
    }
  };
  const lines = reply ? ledgerLines(reply, group) : [];
  // acpmux returns at most LEDGER_ROW_LIMIT sessions, the most recent; the totals count them all.
  const moreSessions =
    group === "session" && reply && reply.totals.sessions > reply.rows.length ? reply.totals.sessions : undefined;
  const status =
    state.phase === "older"
      ? t("ledger.older")
      : state.phase === "failed"
        ? t("ledger.failed")
        : !reply
          ? t("ledger.loading")
          : lines.length === 0
            ? t("ledger.empty")
            : "";

  const renderRow = (index: number, style: React.CSSProperties) => {
    const line = lines[index];
    if (!line) return null;
    return (
      <Line
        key={`${group}:${line.key}`}
        line={line}
        label={groupLabel(group, line, locale)}
        look={look}
        locale={locale}
        style={style}
        onOpen={line.sessionId ? openSession : undefined}
      />
    );
  };

  return (
    <div className="cst" data-look={look} data-loading={state.phase === "loading" || undefined}>
      <div className="cst-controls">
        <Tabs variant="segmented" value={range} onValueChange={(value) => setRange(value as LedgerRange)}>
          <TabsList aria-label={t("ledger.range")}>
            {LEDGER_RANGES.map((each) => (
              <TabsTrigger key={each} value={each}>
                {t(`ledger.range.${each}`)}
              </TabsTrigger>
            ))}
          </TabsList>
        </Tabs>
        <span className="cst-fill" />
        {save && (
          <Menu {...(initialExportOpen ? { open: true } : {})}>
            <MenuButton
              className="cst-link"
              data-menu="costs-export"
              label={t("ledger.export")}
              // Only an answer for the range on screen: never an older range's rows under this one's name.
              disabled={state.phase !== "ready"}
            >
              {t("ledger.export")}
            </MenuButton>
            <MenuPopup side="bottom" align="end" className="acpmux-quick-menu" label={t("ledger.export")}>
              <MenuItem className="acpmux-quick-item" onSelect={() => void runExport("csv")}>
                {t("ledger.export.csv")}
              </MenuItem>
              <MenuItem className="acpmux-quick-item" onSelect={() => void runExport("json")}>
                {t("ledger.export.json")}
              </MenuItem>
            </MenuPopup>
          </Menu>
        )}
        <Select
          label={t("ledger.group")}
          value={group}
          closeOnPick
          align="end"
          options={LEDGER_GROUPS.map((each) => ({ value: each, label: t(`ledger.group.${each}`) }))}
          onChange={(value) => setGroup(value as LedgerGroup)}
        />
      </div>
      <Strip totals={reply?.totals} locale={locale} t={t} />
      <div className="cst-table-note">
        {reply?.priceTable && <span>{t("ledger.priceTable", { version: reply.priceTable.version })}</span>}
        {reply && reply.totals.unpricedTurns > 0 && (
          <span>{t("ledger.unpriced", { n: formatCount(reply.totals.unpricedTurns, locale) })}</span>
        )}
        {exported && (
          <span className="cst-exported" data-tone={exported === "failed" ? "error" : undefined} role="status">
            {t(`ledger.export.${exported}`)}
          </span>
        )}
        {moreSessions !== undefined && (
          <span>
            {t("ledger.more", {
              shown: formatCount(reply!.rows.length, locale),
              total: formatCount(moreSessions, locale),
            })}
          </span>
        )}
        <span className="cst-fill" />
        {/* What the marks after a cost mean, for the marks this list shows. */}
        {LEGEND.filter((source) => lines.some((line) => line.source === source)).map((source) => (
          <span key={source} className="cst-legend">
            <SourceMark source={source} />
            {t(SOURCE_KEY[source]!)}
          </span>
        ))}
      </div>
      {look === "table" && lines.length > 0 && (
        <div className="cst-head" aria-hidden="true">
          <span className="cst-head-label">{t(`ledger.group.${group}`)}</span>
          <span>{t("ledger.total.cost")}</span>
          <span>{t("ledger.total.tokensIn")}</span>
          <span>{t("ledger.column.cacheRead")}</span>
          <span>{t("ledger.column.cacheWrite")}</span>
          <span>{t("ledger.column.hitRate")}</span>
          <span>{t("ledger.total.tokensOut")}</span>
          <span>{t("ledger.total.turns")}</span>
          <span>{t("ledger.total.time")}</span>
        </div>
      )}
      <div className="cst-scroll">
        {lines.length > 0 && (
          <VirtualList
            className="cst-list"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- VirtualList's role prop, its scroller is a div
            role="list"
            label={t("ledger.title")}
            count={lines.length}
            estimateSize={() => ROW_HEIGHT[look]}
            overscan={8}
            renderRow={renderRow}
          />
        )}
        <div className="cst-status" aria-live="polite">
          {status}
          {state.phase === "failed" && (
            <button type="button" className="cst-link" onClick={() => read(range)}>
              {t("ledger.retry")}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

function Strip({ totals, locale, t }: { totals?: LedgerTotals; locale: string; t: Translate }) {
  // The tiles hold their place before the first answer: dashes, never a strip that pops in.
  const value = (render: (totals: LedgerTotals) => string) => (totals ? render(totals) : "–");
  const tiles: [string, string][] = [
    [t("ledger.total.cost"), value((each) => formatCost(each.costUsd, locale))],
    [t("ledger.total.tokensIn"), value((each) => formatCount(tokensIn(each), locale))],
    [t("ledger.total.cacheRead"), value((each) => formatCount(each.cacheReadTokens, locale))],
    [t("ledger.total.cacheWrite"), value((each) => formatCount(each.cacheWriteTokens, locale))],
    [t("ledger.total.hitRate"), value((each) => hitRateText(each, locale))],
    [t("ledger.total.tokensOut"), value((each) => formatCount(each.outputTokens, locale))],
    [t("ledger.total.turns"), value((each) => formatCount(each.turns, locale))],
    [t("ledger.total.tools"), value((each) => formatCount(each.toolCalls, locale))],
    [t("ledger.total.time"), value((each) => formatDuration(each.wallMs, locale))],
  ];
  return (
    <dl className="cst-strip">
      {tiles.map(([label, shown]) => (
        <div key={label} className="cst-tile">
          <dt>{label}</dt>
          <dd>{shown}</dd>
        </div>
      ))}
    </dl>
  );
}

/// The cache hit rate in the page's language; the unknown mark with no prompt tokens.
function hitRateText(totals: LedgerTotals, locale: string): string {
  const rate = cacheHitRate(totals);
  return rate === undefined ? UNKNOWN : usageShare(rate, locale);
}

const SOURCE_KEY: Record<
  CostSource,
  "ledger.source.harness" | "ledger.source.table" | "ledger.source.mixed" | "ledger.source.unpriced" | undefined
> = {
  harness: "ledger.source.harness",
  table: "ledger.source.table",
  mixed: "ledger.source.mixed",
  unpriced: "ledger.source.unpriced",
  none: undefined,
};

const LEGEND: readonly CostSource[] = ["table", "mixed", "unpriced"];

/// One row. Memoized: a row redraws only when its own numbers change.
const Line = memo(function Line({
  line,
  label,
  look,
  locale,
  style,
  onOpen,
}: {
  line: LedgerLine;
  label: string;
  look: LedgerLook;
  locale: string;
  style: React.CSSProperties;
  onOpen?: (sessionId: string) => void;
}) {
  const t = useT();
  const { totals } = line;
  const sourceKey = SOURCE_KEY[line.source];
  const source = sourceKey ? t(sourceKey) : undefined;
  const cost = formatCost(totals.costUsd, locale);
  const rate = cacheHitRate(totals);
  const counts = t("ledger.row.meta", {
    turns: formatCount(totals.turns, locale),
    tokens: formatCount(tokensIn(totals) + totals.outputTokens, locale),
  });
  const meta =
    rate === undefined ? counts : `${counts} · ${t("ledger.row.cacheHit", { rate: usageShare(rate, locale) })}`;
  const bar = (
    <span className="cst-bar" style={{ "--cst-share": line.share } as React.CSSProperties} aria-hidden="true" />
  );
  const body =
    look === "table" ? (
      <>
        <span className="cst-label">{label}</span>
        <span className="cst-num" title={source}>
          {cost}
          <SourceMark source={line.source} />
        </span>
        <span className="cst-num">{formatCount(tokensIn(totals), locale)}</span>
        <span className="cst-num">{formatCount(totals.cacheReadTokens, locale)}</span>
        <span className="cst-num">{formatCount(totals.cacheWriteTokens, locale)}</span>
        <span className="cst-num">{hitRateText(totals, locale)}</span>
        <span className="cst-num">{formatCount(totals.outputTokens, locale)}</span>
        <span className="cst-num">{formatCount(totals.turns, locale)}</span>
        <span className="cst-num">{formatDuration(totals.wallMs, locale)}</span>
        {bar}
      </>
    ) : (
      <>
        {look === "bars" && bar}
        <span className="cst-text">
          <span className="cst-label">{label}</span>
          <span className="cst-detail">{line.detail ? `${line.detail} · ${meta}` : meta}</span>
        </span>
        <span className="cst-cost" title={source}>
          {cost}
          <SourceMark source={line.source} />
        </span>
        {look === "stacked" && bar}
      </>
    );
  return (
    <div
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a virtualized row (absolute, transformed), not a flow <li>
      role="listitem"
      className="cst-item"
      style={style}
    >
      {onOpen && line.sessionId ? (
        <button
          type="button"
          className="cst-row"
          data-look={look}
          aria-label={`${label}, ${cost}${source ? `, ${source}` : ""}`}
          onClick={() => onOpen(line.sessionId!)}
        >
          {body}
        </button>
      ) : (
        <div className="cst-row" data-look={look}>
          {body}
        </div>
      )}
    </div>
  );
});

/// Where the cost came from, as a small mark after it: none for a cost the agent reported, a
/// hollow dot for one priced from the table, half for a mix, a dash for no price.
function SourceMark({ source }: { source: CostSource }) {
  if (source === "harness" || source === "none") return null;
  return <span className="cst-source" data-source={source} aria-hidden="true" />;
}
