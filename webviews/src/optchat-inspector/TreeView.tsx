import { useState } from "react";
import { Term } from "./Term";
import { formatBytes, parseName } from "./model";
import type { Level, NodeBrief, NodeDetail, SearchHit, Status } from "./types";
import { useApi } from "./useApi";

type Props = {
  path: string[];
  status?: Status;
  viewParts: string[];
  onFocus: (name: string) => void;
  onReset: () => void;
};

/** The memory tree: zoom panel with breadcrumb, search, date lookup, and one strip per level. */
export function TreeView({ path, status, viewParts, onFocus, onReset }: Props) {
  const focus = path[path.length - 1];
  return (
    <section className="tree" aria-label="Tree">
      <div className="bar">
        <Search onFocus={onFocus} />
        <DateLookup />
      </div>
      <nav className="crumbs" aria-label="Zoom path">
        <button onClick={onReset}>The view</button>
        {path.map((name, i) => (
          <span key={name}>
            {" › "}
            {i === path.length - 1 ? <b>{name}</b> : <button onClick={() => onFocus(name)}>{name}</button>}
          </span>
        ))}
        {path.length > 1 && <span className="muted"> ({path.length - 1} zoom hops)</span>}
      </nav>
      {focus ? (
        <Focus name={focus} onFocus={onFocus} />
      ) : (
        <p className="muted">
          Pick a line in the Prompt tab, a node below, or a search result. The agent starts from the{" "}
          <Term id="view">view</Term> and <Term id="zoom">zooms</Term> the same way.
        </p>
      )}
      {status && status.messages > 0 && <Levels status={status} viewParts={viewParts} path={path} onFocus={onFocus} />}
    </section>
  );
}

function Focus({ name, onFocus }: { name: string; onFocus: (name: string) => void }) {
  const { data, error } = useApi<NodeDetail>(`/api/node?name=${encodeURIComponent(name)}`);
  if (error) return <p className="error">{error}</p>;
  if (!data) return <p className="muted">Loading…</p>;
  return (
    <div className="focus">
      <div className="card">
        <h3>
          <Term id="node">Node</Term> {data.name}{" "}
          <span className="muted">
            <Term id="level">level</Term> {data.level}: messages {data.start}–{data.end - 1}
            {data.in_view ? ", a line of the current view" : ""}
          </span>
        </h3>
        <p className="muted">
          {data.date_first}
          {data.n > 1 ? ` to ${data.date_last}` : ""} · {data.built ? formatBytes(data.bytes) : "not built yet"}
          {data.parent && (
            <>
              {" · "}
              <button className="link" onClick={() => onFocus(data.parent!)}>
                parent {data.parent}
              </button>
            </>
          )}
        </p>
        <pre className={data.built ? "" : "placeholder"}>{data.text ?? "(not summarized yet: zoom it)"}</pre>
      </div>
      <div className="card agent">
        <h4>
          What the agent gets from <code>{data.zoom.call}</code>
        </h4>
        <pre>{data.zoom.answer}</pre>
      </div>
      {data.children ? (
        <div className="kids">
          {data.children.map((c) => (
            <Child key={c.name} node={c} onFocus={onFocus} />
          ))}
        </div>
      ) : (
        data.message && (
          <div className="card">
            <h4>
              Message {data.message.id} in full{" "}
              <span className="muted">
                ({data.message.kind}, {formatBytes(data.message.bytes)})
              </span>
            </h4>
            <pre>{data.message.text}</pre>
          </div>
        )
      )}
    </div>
  );
}

function Child({ node, onFocus }: { node: NodeBrief; onFocus: (name: string) => void }) {
  return (
    <div className="card child">
      <div className="row">
        <b>{node.name}</b>
        <button onClick={() => onFocus(node.name)} title={`zoom(${node.start}, ${node.n})`}>
          {node.n === 1 ? "Open message" : "Zoom in"}
        </button>
      </div>
      <p className={node.built ? "" : "placeholder"}>{node.text ?? "(not summarized yet: zoom it)"}</p>
    </div>
  );
}

function Levels({
  status,
  viewParts,
  path,
  onFocus,
}: {
  status: Status;
  viewParts: string[];
  path: string[];
  onFocus: (n: string) => void;
}) {
  const top = status.top_level ?? 0;
  const levels = Array.from({ length: top + 1 }, (_, i) => top - i);
  return (
    <div className="card levels">
      <h3>
        Levels <span className="muted">(newest on the right; raw messages at the bottom)</span>
      </h3>
      {levels.map((l) => (
        <LevelStrip key={l} level={l} viewParts={viewParts} path={path} onFocus={onFocus} />
      ))}
    </div>
  );
}

const STRIP = 48;

function LevelStrip({
  level,
  viewParts,
  path,
  onFocus,
}: {
  level: number;
  viewParts: string[];
  path: string[];
  onFocus: (n: string) => void;
}) {
  const [from, setFrom] = useState<number | null>(null);
  const url = `/api/level?l=${level}&limit=${STRIP}${from != null ? `&from=${from}` : ""}`;
  const { data } = useApi<Level>(url);
  const inView = new Set(viewParts);
  const onPath = new Set(path);
  return (
    <div className="strip">
      <span className="lvlabel" title={`Each node covers ${2 ** level} message${level ? "s" : ""}`}>
        L{level}
      </span>
      <button
        className="page"
        disabled={!data || data.from === 0}
        onClick={() => setFrom(Math.max(0, (data?.from ?? 0) - STRIP))}
        aria-label="Older"
      >
        ‹
      </button>
      <div className="cells">
        {data?.nodes.map((n) => (
          <button
            key={n.name}
            className={[
              "cell",
              n.built ? "built" : "unbuilt",
              inView.has(n.name) ? "inview" : "",
              onPath.has(n.name) ? "onpath" : "",
            ].join(" ")}
            title={`${n.name}${inView.has(n.name) ? " (in the view)" : ""}: ${n.text ?? "not built"}`}
            aria-label={n.name}
            onClick={() => onFocus(n.name)}
          />
        ))}
      </div>
      <button
        className="page"
        disabled={!data || data.from + data.nodes.length >= data.count}
        onClick={() => setFrom((data?.from ?? 0) + STRIP)}
        aria-label="Newer"
      >
        ›
      </button>
      <span className="muted count">{data ? `${data.count} nodes` : ""}</span>
    </div>
  );
}

function Search({ onFocus }: { onFocus: (name: string) => void }) {
  const [q, setQ] = useState("");
  const [asked, setAsked] = useState("");
  const { data, error } = useApi<{ hits: SearchHit[] }>(asked ? `/api/search?q=${encodeURIComponent(asked)}` : null);
  return (
    <div className="search">
      <form
        onSubmit={(e) => {
          e.preventDefault();
          const direct = parseName(q);
          if (direct) onFocus(q.trim());
          else setAsked(q.trim());
        }}
      >
        <input
          type="search"
          placeholder="Search memory, or a node like 128+64"
          value={q}
          onChange={(e) => setQ(e.currentTarget.value)}
          aria-label="Search"
        />
      </form>
      {error && <p className="error">{error}</p>}
      {asked && data && (
        <ul className="hits">
          {data.hits.length === 0 && <li className="muted">No match for “{asked}”.</li>}
          {data.hits.map((h) => (
            <li key={`${h.type}-${h.name}`}>
              <button onClick={() => onFocus(h.name)}>{h.name}</button>{" "}
              <span className="muted">
                {h.type === "message" ? `message (${h.kind})` : `summary, level ${h.level}`}
              </span>{" "}
              <span className="snippet">{h.snippet}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function DateLookup() {
  const [id, setId] = useState("");
  const [asked, setAsked] = useState<string | null>(null);
  const { data, error } = useApi<{ date: string; call: string }>(
    asked != null ? `/api/date?id=${encodeURIComponent(asked)}` : null,
  );
  return (
    <form
      className="date"
      onSubmit={(e) => {
        e.preventDefault();
        setAsked(id.trim());
      }}
    >
      <label>
        <Term id="date">date(id)</Term>{" "}
        <input
          inputMode="numeric"
          size={8}
          value={id}
          onChange={(e) => setId(e.currentTarget.value)}
          aria-label="Message id"
        />
      </label>
      {asked != null && (error ? <span className="error">{error}</span> : data && <span>{data.date}</span>)}
    </form>
  );
}
