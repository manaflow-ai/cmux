import { useState } from "react";
import { LiveView } from "./LiveView";
import { PromptView } from "./PromptView";
import { Term } from "./Term";
import { TimelineView } from "./TimelineView";
import { TreeView } from "./TreeView";
import { nextPath } from "./model";
import type { Status, TurnPrompt, TurnRow } from "./types";
import { useApi } from "./useApi";

export type Tab = "prompt" | "tree" | "timeline" | "live";

const TABS: { id: Tab; label: string; hint: string }[] = [
  { id: "prompt", label: "Prompt", hint: "What the model saw at a turn" },
  { id: "tree", label: "Tree", hint: "Zoom through the memory like the agent does" },
  { id: "timeline", label: "Timeline", hint: "Every turn: time, cache, tools, compactor" },
  { id: "live", label: "Live", hint: "Settle progress, running turn, errors" },
];

/** The Chief memory inspector: four tabs over one shared turn choice and zoom path. */
export function App({ initialTab = "prompt" }: { initialTab?: Tab }) {
  const [tab, setTab] = useState<Tab>(initialTab);
  const [turn, setTurn] = useState("now");
  const [path, setPath] = useState<string[]>([]);
  const status = useApi<Status>("/api/status", tab === "live" ? 2000 : undefined);
  const turns = useApi<{ turns: TurnRow[] }>("/api/turns").data?.turns ?? [];
  const now = useApi<TurnPrompt>(tab === "tree" ? "/api/turn?key=now" : null);
  const zoom = (name: string) => {
    setPath((p) => nextPath(p, name));
    setTab("tree");
  };
  const s = status.data;
  return (
    <div className="app">
      <header className="top">
        <h1>Chief memory</h1>
        {s && (
          <p className="summary">
            {s.messages} messages · {s.view_lines} <Term id="view">view</Term> lines ·{" "}
            {s.settled ? "settled" : `${s.unbuilt} unsummarized`}
            {s.running_turn ? " · a turn is running" : ""}
          </p>
        )}
        {status.error && <p className="error">{status.error}</p>}
      </header>
      <div className="tabs" role="tablist">
        {TABS.map((t) => (
          <button key={t.id} role="tab" aria-selected={tab === t.id} title={t.hint} onClick={() => setTab(t.id)}>
            {t.label}
          </button>
        ))}
      </div>
      <main>
        {tab === "prompt" && <PromptView turn={turn} turns={turns} onTurn={setTurn} onZoom={zoom} />}
        {tab === "tree" && (
          <TreeView
            path={path}
            status={s}
            viewParts={now.data?.view?.parts ?? []}
            onFocus={(name) => setPath((p) => nextPath(p, name))}
            onReset={() => {
              setPath([]);
              setTab("prompt");
            }}
          />
        )}
        {tab === "timeline" && (
          <TimelineView
            turns={turns}
            onPick={(key) => {
              setTurn(key);
              setTab("prompt");
            }}
          />
        )}
        {tab === "live" && <LiveView status={s} />}
      </main>
    </div>
  );
}
