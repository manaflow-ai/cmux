import { Term } from "./Term";
import { formatMs, formatPct, topTools, turnLabel } from "./model";
import type { TurnRow } from "./types";

/** One row per traced turn; a click opens that turn's prompt. */
export function TimelineView({ turns, onPick }: { turns: TurnRow[]; onPick: (key: string) => void }) {
  if (turns.length === 0) return <p className="muted">No turns in the trace yet (the last 14 days are read).</p>;
  const longest = Math.max(1, ...turns.map((t) => t.ms ?? 0));
  return (
    <section className="timeline" aria-label="Timeline">
      <table>
        <thead>
          <tr>
            <th>
              <Term id="turn">Turn</Term>
            </th>
            <th>Took</th>
            <th>
              <Term id="settle">Settle wait</Term>
            </th>
            <th>
              <Term id="cache">Cache hit</Term>
            </th>
            <th>Tools</th>
            <th>Harness · model</th>
            <th>
              <Term id="compactor">Nodes built</Term>
            </th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          {[...turns].reverse().map((t) => (
            <tr key={t.turn} onClick={() => onPick(t.turn)}>
              <td>
                <button className="link" onClick={() => onPick(t.turn)}>
                  {turnLabel(t)}
                </button>
              </td>
              <td>
                <span className="latency" style={{ width: `${(60 * (t.ms ?? 0)) / longest}px` }} /> {formatMs(t.ms)}
              </td>
              <td>{formatMs(t.settle_ms)}</td>
              <td>{formatPct(t.hit_rate)}</td>
              <td title={JSON.stringify(t.tool_names ?? {})}>
                {t.tools ?? 0} {t.tools ? `(${topTools(t.tool_names)})` : ""}
              </td>
              <td>
                {t.harness ?? "–"}
                {t.model ? ` · ${t.model}` : ""}
              </td>
              <td title="before the turn (its settle) / during it">
                {t.nodes_before ?? 0} / {t.nodes_during ?? 0}
              </td>
              <td className={t.status === "ok" ? "" : "warn"}>
                {t.status ?? "running"}
                {t.error ? `: ${t.error}` : ""}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
