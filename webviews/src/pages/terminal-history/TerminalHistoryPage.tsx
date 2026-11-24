import { useEffect, useMemo, useRef, useSyncExternalStore } from "react";
import type { TerminalHistoryStore } from "./store";
import type { TranscriptHit, TranscriptTurn } from "./types";

export type TerminalHistoryPageProps = {
  store: TerminalHistoryStore;
  fixture?: { title?: string; turns?: TranscriptTurn[]; before?: number | null; query?: string };
};

export function TerminalHistoryPage({ store, fixture }: TerminalHistoryPageProps) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const viewport = useRef<HTMLDivElement>(null);
  const turns = fixture?.turns ?? snapshot.turns;
  const title = fixture?.title ?? snapshot.title;
  const query = fixture?.query ?? snapshot.query;
  const hitSet = useMemo(() => snapshot.hits.map((hit) => hit.snippet.toLocaleLowerCase()), [snapshot.hits]);

  useEffect(() => {
    if (!fixture) void store.load();
  }, [fixture, store]);

  const onScroll = () => {
    const element = viewport.current;
    if (element && element.scrollTop < 420) void store.loadOlder();
  };

  return (
    <main className="terminal-history-page">
      <header className="terminal-history-header">
        <div>
          <p className="terminal-history-kicker">Read-only transcript</p>
          <h1>{title}</h1>
          <p className="terminal-history-meta">Earlier turns stay available after a terminal restart.</p>
        </div>
        <label className="terminal-history-search">
          <span>Find in transcript</span>
          <input
            type="search"
            value={query}
            placeholder="Search all turns"
            onChange={(event) => void store.find(event.target.value)}
          />
          <kbd>⌘F</kbd>
        </label>
      </header>
      {snapshot.error && !fixture ? <p className="terminal-history-error" role="alert">{snapshot.error}</p> : null}
      <div className="terminal-history-scroll" ref={viewport} onScroll={onScroll}>
        {snapshot.loading && !fixture ? <p className="terminal-history-status">Loading latest turns…</p> : null}
        {snapshot.loadingOlder ? <p className="terminal-history-status terminal-history-status-top">Loading earlier turns…</p> : null}
        {turns.length === 0 && !snapshot.loading ? <p className="terminal-history-status">No transcript turns found.</p> : null}
        {turns.map((turn, index) => <Turn key={`${index}-${turn.promptAt ?? ""}`} turn={turn} index={index} highlighted={hitSet.some((snippet) => `${turn.prompt}\n${turn.answer}`.toLocaleLowerCase().includes(snippet))} />)}
        {snapshot.hits.length > 0 ? <nav className="terminal-history-results" aria-label="Search results"><span>{snapshot.hits.length} matches</span>{snapshot.hits.slice(0, 12).map((hit, index) => <button key={`${hit.pageEnd}-${hit.turn}-${index}`} type="button" onClick={() => void jumpToHit(store, hit)}>{hit.snippet}</button>)}</nav> : null}
        {snapshot.before !== null && !fixture ? <button type="button" className="terminal-history-older" onClick={() => void store.loadOlder()}>Load earlier history</button> : null}
        {snapshot.hasNewer && !fixture ? <button type="button" className="terminal-history-older" onClick={() => void store.returnToLatest()}>Back to latest</button> : null}
      </div>
    </main>
  );
}

async function jumpToHit(store: TerminalHistoryStore, hit: TranscriptHit): Promise<void> {
  await store.jumpToHit(hit);
  requestAnimationFrame(() => {
    const match = Array.from(document.querySelectorAll<HTMLElement>(".terminal-history-turn")).find((element) =>
      element.textContent?.toLocaleLowerCase().includes(hit.snippet.toLocaleLowerCase()),
    );
    match?.scrollIntoView({ block: "center", behavior: "smooth" });
  });
}

function Turn({ turn, index, highlighted }: { turn: TranscriptTurn; index: number; highlighted: boolean }) {
  return (
    <article className={`terminal-history-turn${highlighted ? " is-highlighted" : ""}`} data-turn={index}>
      <div className="terminal-history-turn-marker" aria-hidden="true">{index + 1}</div>
      <div className="terminal-history-turn-body">
        <section className="terminal-history-message terminal-history-message-user"><h2>You</h2><p>{turn.prompt}</p></section>
        {turn.tools.length > 0 ? <details className="terminal-history-tools"><summary>{turn.tools.length} tool call{turn.tools.length === 1 ? "" : "s"}</summary><ul>{turn.tools.map((tool, toolIndex) => <li key={`${tool.title}-${toolIndex}`}>{tool.title}</li>)}</ul></details> : null}
        <section className="terminal-history-message terminal-history-message-assistant"><h2>Agent</h2><p>{turn.answer}</p></section>
      </div>
    </article>
  );
}
