// The team board (`cmux-page://cmux.board/`): every machine and agent of the team on one screen,
// who started it, what it is doing, whether an agent waits on a person, what it has cost, with
// Stop and Open. State lives in `BoardStore`; this file renders it.
//
// The list is windowed: only the rows in view (plus a few above and below) are in the DOM, every
// row is ROW_HEIGHT tall, and each row reads its own record from the store by id. A row opens its
// machine (the name is the row's button); Stop takes the cost's place while the row is hovered or
// focused, so the list carries no column of repeated buttons. Opening and
// scrolling cost the same at 3 machines and at 5,000 (README.md "Perf"); a change to one machine
// re-renders that row only.
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import type { Strings } from "../shared/i18n";
import { isRunning, type BoardFilter, type BoardRow, type BoardTotals, type Owner } from "./model";
import type { BoardStore, RowView } from "./store";

/** One row's height in CSS pixels (styles.css `--board-row`). */
export const ROW_HEIGHT = 52;
/** Rows rendered above and below the viewport. */
export const OVERSCAN = 8;

/** The rows a viewport shows: [first, end). */
export function windowOf(scrollTop: number, viewport: number, count: number): [number, number] {
  // A scroll offset past the end (the list just got shorter) shows the last screen.
  const top = Math.max(0, Math.min(scrollTop, count * ROW_HEIGHT - viewport));
  const first = Math.max(0, Math.floor(top / ROW_HEIGHT) - OVERSCAN);
  const end = Math.min(count, Math.ceil((top + viewport) / ROW_HEIGHT) + OVERSCAN);
  return [first, Math.max(first, end)];
}

const FILTERS: BoardFilter[] = ["all", "running", "waiting", "unowned"];

export function BoardPage({
  store,
  strings,
  windowed = true,
}: {
  store: BoardStore;
  strings: Strings;
  /** False puts every row in the DOM: the perf harness's "before" (bench/board/run.ts), never shipped. */
  windowed?: boolean;
}) {
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t, format } = strings;
  const money = useMoney(strings.language);

  if (state.unavailable)
    return (
      <div className="board-page">
        <p className="board-message">{t("board.unavailable")}</p>
      </div>
    );

  return (
    <div className="board-page" aria-busy={state.loading || undefined}>
      <header className="board-header">
        <h1 className="board-title">{t("board.title")}</h1>
        <Totals totals={state.totals} strings={strings} money={money} />
        <div className="board-controls">
          <fieldset className="board-filters" aria-label={t("board.filter.label")}>
            {FILTERS.map((filter) => (
              <button
                key={filter}
                type="button"
                aria-pressed={state.filter === filter}
                className="board-filter"
                onClick={() => store.setFilter(filter)}
              >
                {t(`board.filter.${filter}`)}
              </button>
            ))}
          </fieldset>
          <input
            className="board-search"
            type="search"
            placeholder={t("board.search")}
            aria-label={t("board.search")}
            value={state.query}
            onChange={(event) => store.setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape" && state.query && !event.metaKey && !event.ctrlKey && !event.altKey) {
                store.setQuery("");
                event.preventDefault();
              }
            }}
          />
        </div>
      </header>
      {state.failure && (
        <div className="board-notice" role="alert">
          <span>{format("board.failed", state.failure)}</span>
          <button type="button" className="board-button" onClick={() => void store.refresh()}>
            {t("board.retry")}
          </button>
        </div>
      )}
      <div className="board-columns" aria-hidden="true">
        <span>{t("board.col.machine")}</span>
        <span>{t("board.col.doing")}</span>
        <span className="board-num">{t("board.col.cost")}</span>
      </div>
      {state.visible.length === 0 && !state.loading ? (
        <p className="board-message">
          {state.filter === "all" && !state.query ? t("board.empty") : t("board.empty.filtered")}
        </p>
      ) : (
        <BoardList ids={state.visible} store={store} strings={strings} money={money} windowed={windowed} />
      )}
    </div>
  );
}

type Money = { total: (usd: number) => string; rate: (usd: number) => string };

function useMoney(language: string): Money {
  const [money] = useState<Money>(() => {
    const total = new Intl.NumberFormat(language, { style: "currency", currency: "USD", maximumFractionDigits: 2 });
    const rate = new Intl.NumberFormat(language, { style: "currency", currency: "USD", maximumFractionDigits: 3 });
    return { total: (usd) => total.format(usd), rate: (usd) => rate.format(usd) };
  });
  return money;
}

function Totals({ totals, strings, money }: { totals: BoardTotals; strings: Strings; money: Money }) {
  const { t, language } = strings;
  const [count] = useState(() => new Intl.NumberFormat(language));
  const stat = (key: string, value: string, tone?: string) => (
    <div className={`board-stat${tone ? ` ${tone}` : ""}`} key={key}>
      <span className="board-stat-value">{value}</span>
      <span className="board-stat-label">{t(key)}</span>
    </div>
  );
  return (
    <div className="board-stats">
      {stat("board.stat.machines", count.format(totals.machines))}
      {stat("board.stat.running", count.format(totals.running))}
      {stat("board.stat.waiting", count.format(totals.waiting), totals.waiting > 0 ? "attention" : undefined)}
      {stat("board.stat.unowned", count.format(totals.unowned), totals.unowned > 0 ? "attention" : undefined)}
      {stat("board.stat.cost", money.total(Math.max(0, totals.costUsd)))}
      {stat("board.stat.rate", money.rate(Math.max(0, totals.hourlyUsd)))}
      {totals.unknownCost > 0 && stat("board.stat.unknownCost", count.format(totals.unknownCost), "attention")}
    </div>
  );
}

function BoardList({
  ids,
  store,
  strings,
  money,
  windowed,
}: {
  ids: readonly string[];
  store: BoardStore;
  strings: Strings;
  money: Money;
  windowed: boolean;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const [scrollTop, setScrollTop] = useState(0);
  const [viewport, setViewport] = useState(800);

  useLayoutEffect(() => {
    const element = scroller.current;
    if (!element) return;
    setViewport(element.clientHeight || 800);
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(() => setViewport(element.clientHeight || 800));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  // A shorter list (a filter, a search) cannot leave the window past its end.
  useEffect(() => {
    const element = scroller.current;
    if (element && element.scrollTop !== scrollTop) setScrollTop(element.scrollTop);
  }, [ids, scrollTop]);

  const [first, end] = windowed ? windowOf(scrollTop, viewport, ids.length) : [0, ids.length];
  const rows: ReactNode[] = [];
  for (let index = first; index < end; index += 1) {
    const id = ids[index]!;
    rows.push(
      <BoardRowView key={id} id={id} index={index} count={ids.length} store={store} strings={strings} money={money} />,
    );
  }
  return (
    <div ref={scroller} className="board-list" onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}>
      <ul className="board-list-body" style={{ height: ids.length * ROW_HEIGHT }}>
        {rows}
      </ul>
    </div>
  );
}

const BoardRowView = memo(function BoardRowView({
  id,
  index,
  count,
  store,
  strings,
  money,
}: {
  id: string;
  index: number;
  count: number;
  store: BoardStore;
  strings: Strings;
  money: Money;
}) {
  const subscribe = useCallback((listener: () => void) => store.subscribeRow(id, listener), [store, id]);
  const view = useSyncExternalStore(subscribe, () => store.getRow(id));
  if (!view) return null;
  return <RowBody view={view} index={index} count={count} store={store} strings={strings} money={money} />;
});

function RowBody({
  view,
  index,
  count,
  store,
  strings,
  money,
}: {
  view: RowView;
  index: number;
  count: number;
  store: BoardStore;
  strings: Strings;
  money: Money;
}) {
  const { row, stopping, refused } = view;
  const { t } = strings;
  const running = isRunning(row.state);
  const stoppable = running || stopping;
  // Stop says which machine it acts on (the name, which is also the row's Open button).
  const nameId = `board-name-${row.id}`;
  return (
    <li
      className="board-row"
      data-state={row.state}
      data-waiting={row.waiting || undefined}
      data-stoppable={stoppable || undefined}
      data-stopping={stopping || undefined}
      // Only the rows in view are in the DOM: the position and count say where this one is in the whole list.
      aria-posinset={index + 1}
      aria-setsize={count}
      style={{ transform: `translateY(${index * ROW_HEIGHT}px)` }}
    >
      <div className="board-cell board-machine">
        <button
          type="button"
          className="board-name board-open"
          id={nameId}
          title={row.title}
          aria-label={strings.format("board.openMachine", row.title)}
          onClick={() => void store.openMachine(row.id)}
        >
          {row.title}
        </button>
        <span className="board-sub">
          <OwnerText owner={row.owner} strings={strings} />
          {row.origin && (
            <span className="board-origin" title={row.origin.label}>
              {row.origin.label}
            </span>
          )}
        </span>
      </div>
      <div className="board-cell board-doing">
        <span className="board-state">
          {row.waiting && <span className="board-dot attention" aria-hidden="true" />}
          <span className="board-state-text">{doingText(row, strings)}</span>
        </span>
        {refused ? (
          <output className="board-sub board-refused">{refused}</output>
        ) : (
          <span className="board-sub">{lastText(row, strings)}</span>
        )}
      </div>
      <div className="board-cell board-num board-cost">
        <span title={row.costUsd === null ? t("board.cost.unknown") : undefined}>
          {row.costUsd === null ? "—" : money.total(row.costUsd)}
        </span>
        <span className="board-sub">
          {running && row.hourlyUsd !== null ? strings.format("board.rate", money.rate(row.hourlyUsd)) : ""}
        </span>
      </div>
      {stoppable && (
        <div className="board-cell board-actions">
          <button
            type="button"
            className="board-button danger"
            aria-describedby={nameId}
            disabled={stopping}
            onClick={() => void store.stopMachine(row.id)}
          >
            {stopping ? t("board.stopping") : t("board.stop")}
          </button>
        </div>
      )}
    </li>
  );
}

function OwnerText({ owner, strings }: { owner: Owner; strings: Strings }) {
  const { t } = strings;
  switch (owner.kind) {
    case "self":
      return <span className="board-owner">{t("board.owner.you")}</span>;
    case "member":
      return (
        <span className="board-owner" title={owner.name}>
          {owner.name}
        </span>
      );
    case "unknown":
      return (
        <span className="board-owner attention" title={owner.user}>
          {strings.format("board.owner.notMember", owner.user)}
        </span>
      );
    case "none":
      return <span className="board-owner attention">{t("board.owner.none")}</span>;
  }
}

const KNOWN_ACTIONS = new Set(["create", "pause", "resume", "snapshot", "fork", "delete", "open", "restore"]);

/** What the machine is doing: its first agent's state and task, else the machine's state. */
export function doingText(row: BoardRow, strings: Strings): string {
  const session = row.sessions[0];
  if (session && isRunning(row.state)) {
    const state = strings.t(`board.session.${session.state}`);
    return session.title ? `${state} · ${session.agent} · ${session.title}` : `${state} · ${session.agent}`;
  }
  if (row.error) return `${strings.t("board.state.failed")} · ${row.error}`;
  return strings.t(`board.state.${row.state}`);
}

/** The row's last action and who did it; the action alone when the audit names no one. */
export function lastText(row: Pick<BoardRow, "last">, strings: Pick<Strings, "t" | "format">): string {
  if (!row.last) return "";
  const action = KNOWN_ACTIONS.has(row.last.action) ? strings.t(`board.action.${row.last.action}`) : row.last.action;
  const name = row.last.actor.trim();
  if (!name) return action;
  const actor = row.last.actorKind === "agent" ? strings.format("board.actor.agent", name) : name;
  return strings.format("board.last", action, actor);
}
