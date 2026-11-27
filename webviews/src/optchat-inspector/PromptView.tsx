import { useState } from "react";
import { Term } from "./Term";
import { approxTokens, formatBytes, formatPct, formatTokens, hitRate, lineCuts, segments, turnLabel } from "./model";
import type { TurnPrompt, TurnRow } from "./types";
import { useApi } from "./useApi";

type Props = { turn: string; turns: TurnRow[]; onTurn: (key: string) => void; onZoom: (name: string) => void };

/** What the model saw at one turn: system parts, the view line by line, the new messages. */
export function PromptView({ turn, turns, onTurn, onZoom }: Props) {
  const { data, error, loading } = useApi<TurnPrompt>(`/api/turn?key=${encodeURIComponent(turn)}`);
  const row = turns.find((t) => t.turn === turn);
  return (
    <section className="prompt" aria-label="Prompt">
      <header className="bar">
        <label>
          <Term id="turn">Turn</Term>{" "}
          <select value={turn} onChange={(e) => onTurn(e.currentTarget.value)} aria-label="Turn">
            <option value="now">Now (the next turn's view)</option>
            {[...turns].reverse().map((t) => (
              <option key={t.turn} value={t.turn}>
                {turnLabel(t)}
              </option>
            ))}
          </select>
        </label>
        {data && <Badges prompt={data} />}
      </header>
      {loading && !data && <p className="muted">Loading…</p>}
      {error && <p className="error">{error}</p>}
      {data && <PromptBody prompt={data} row={row} onZoom={onZoom} />}
    </section>
  );
}

function Badges({ prompt }: { prompt: TurnPrompt }) {
  const exact = prompt.exact.view && prompt.exact.system && (prompt.turn === "now" || prompt.exact.messages);
  return (
    <span className="badges">
      <span className={exact ? "badge ok" : "badge warn"}>
        <Term id="exact">{exact ? "Exact bytes" : "Not exact"}</Term>
      </span>
      <span className="badge">
        <Term id="layout">{prompt.layout === "cached" ? "Cached layout" : "Blocks layout"}</Term>
      </span>
      {prompt.harness && (
        <span className="badge">
          {prompt.harness}
          {prompt.model ? ` · ${prompt.model}` : ""}
        </span>
      )}
    </span>
  );
}

function PromptBody({ prompt, row, onZoom }: { prompt: TurnPrompt; row?: TurnRow; onZoom: (name: string) => void }) {
  const segs = segments(prompt.blocks);
  const total = segs.reduce((a, s) => a + s.bytes, 0) || 1;
  return (
    <>
      {prompt.note && <p className="note">{prompt.note}</p>}
      <div className="sizebar" aria-hidden="true">
        {segs.map((s, i) => (
          <span
            key={i}
            className={`seg ${s.tone}`}
            style={{ width: `${(100 * s.bytes) / total}%` }}
            title={`${s.label}: ${formatBytes(s.bytes)}`}
          />
        ))}
      </div>
      <ul className="legend">
        {segs.map((s, i) => (
          <li key={i}>
            <span className={`dot ${s.tone}`} /> {s.label} {formatBytes(s.bytes)} (≈
            {formatTokens(approxTokens(s.bytes))} tokens)
          </li>
        ))}
      </ul>
      {row && <CacheCard row={row} prompt={prompt} />}
      <SystemParts prompt={prompt} />
      <ViewLines prompt={prompt} onZoom={onZoom} />
      {prompt.messages.length > 0 && (
        <details open className="card">
          <summary>
            <h3>New messages ({prompt.messages.length})</h3>
          </summary>
          {prompt.messages.map((m) => (
            <div key={m.id} className="msg">
              <button className="name" onClick={() => onZoom(`${m.id}+1`)} title={`zoom(${m.id}, 1)`}>
                {m.id}+1
              </button>
              <span className="kind">{m.kind}</span>
              <pre>{m.text}</pre>
            </div>
          ))}
        </details>
      )}
    </>
  );
}

function CacheCard({ row, prompt }: { row: TurnRow; prompt: TurnPrompt }) {
  const u = row.first_usage;
  const unchanged = prompt.view?.unchanged_prefix_bytes;
  return (
    <div className="card cache">
      <h3>
        <Term id="cache">Cache</Term> on the first request
      </h3>
      {u ? (
        <div className="cachebar" aria-hidden="true">
          {(["cache_read", "cache_write", "input"] as const).map((k) => {
            const all = u.cache_read + u.cache_write + u.input || 1;
            return <span key={k} className={`seg ${k}`} style={{ width: `${(100 * u[k]) / all}%` }} />;
          })}
        </div>
      ) : (
        <p className="muted">The harness reported no token use for this turn.</p>
      )}
      {u && (
        <p>
          Read {formatTokens(u.cache_read)} · written {formatTokens(u.cache_write)} · uncached {formatTokens(u.input)} ·
          hit {formatPct(hitRate(u))}
        </p>
      )}
      {unchanged != null && prompt.view && (
        <p>
          <Term id="unchanged">Same as the previous turn</Term>: {formatBytes(unchanged)} of{" "}
          {formatBytes(prompt.view.bytes)} of the view (shaded below).
        </p>
      )}
    </div>
  );
}

function SystemParts({ prompt }: { prompt: TurnPrompt }) {
  return (
    <details className="card">
      <summary>
        <h3>System prompt ({prompt.system_parts.length} parts)</h3>
      </summary>
      {prompt.system_parts.map((p) => (
        <details key={p.label} className="part">
          <summary title={p.explain}>
            {p.label} <span className="muted">{formatBytes(p.bytes)}</span>
          </summary>
          <p className="muted">{p.explain}</p>
          <pre>{p.text}</pre>
        </details>
      ))}
    </details>
  );
}

function ViewLines({ prompt, onZoom }: { prompt: TurnPrompt; onZoom: (name: string) => void }) {
  const [filter, setFilter] = useState("");
  const view = prompt.view;
  const lines = prompt.lines ?? [];
  if (!view) return null;
  const cuts = lineCuts(lines, view.marks, view.grid, prompt.blocks, view.unchanged_prefix_bytes);
  const needle = filter.trim().toLowerCase();
  return (
    <div className="card">
      <div className="row">
        <h3>
          The <Term id="view">view</Term>: {lines.length} lines, {formatBytes(view.bytes)}
        </h3>
        <input
          type="search"
          placeholder="Filter lines"
          value={filter}
          onChange={(e) => setFilter(e.currentTarget.value)}
          aria-label="Filter view lines"
        />
      </div>
      <p className="muted">
        Each line is a <Term id="node">node</Term>; click its name to <Term id="zoom">zoom</Term>. Older lines cover
        more messages (higher <Term id="level">level</Term>).
      </p>
      <ol className="lines">
        {lines.map((l, i) => {
          if (needle && !l.text.toLowerCase().includes(needle) && !l.name.includes(needle)) return null;
          const c = cuts[i];
          return (
            <li key={l.name} className={c.unchanged ? "line unchanged" : "line"}>
              <button
                className={`name lv${Math.min(l.level, 9)}`}
                onClick={() => onZoom(l.name)}
                title={`zoom(${l.start}, ${l.n}): level ${l.level}`}
              >
                {l.name}
              </button>
              <span className={l.built ? "text" : "text placeholder"}>{l.text}</span>
              <span className="size">{l.bytes} B</span>
              {(c.systemEnd || c.marker || c.mark) && (
                <span className="cut" role="note">
                  {c.systemEnd && <Term id="mark">end of the system prompt (first cache mark)</Term>}
                  {c.marker && <Term id="marker">our cache marker</Term>}
                  {c.mark && !c.systemEnd && <Term id="mark">cache mark</Term>}
                </span>
              )}
              {c.grid && !c.mark && !c.marker && <span className="gridcut" aria-hidden="true" />}
            </li>
          );
        })}
      </ol>
    </div>
  );
}
