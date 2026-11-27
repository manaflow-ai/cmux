import { lazy, memo, Suspense, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { isPromptMarkdown } from "../../agent-session/acpmux/conversation/promptMarkdown";
import { afterPaint } from "../../protocol/intents/schedule";
import { KeyHint } from "../../ui/KeyHint";
import type { Strings } from "../shared/i18n";
import { RawRecord } from "./RawRecord";
import type { TerminalHistoryStore } from "./store";
import { hitTurn, type TranscriptHit, type TranscriptTurn } from "./types";

// Show the transcript text before loading the chat's Markdown and code-rendering dependencies.
const FormattedMessage = lazy(async () => {
  await new Promise<void>((resolve) => afterPaint(resolve));
  return import("./FormattedMessage");
});

export type TerminalHistoryPageProps = {
  store: TerminalHistoryStore;
  strings: Strings;
  fixture?: { title?: string; turns?: TranscriptTurn[]; before?: number | null; query?: string };
};

export function TerminalHistoryPage({ store, strings, fixture }: TerminalHistoryPageProps) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const viewport = useRef<HTMLDivElement>(null);
  const placeLatest = useRef(true);
  const [selected, select] = useState<TranscriptHit>();
  const turns = fixture?.turns ?? snapshot.turns;
  const title = fixture?.title || snapshot.title || strings.t("terminalHistory.tab");
  const query = fixture?.query ?? snapshot.query;
  const hitKeys = useMemo(() => new Set(snapshot.hits.map((hit) => `${hit.pageEnd}:${hitTurn(hit)}`)), [snapshot.hits]);

  useLayoutEffect(() => {
    if (fixture || !placeLatest.current || snapshot.loading || !turns.length || !viewport.current) return;
    placeLatest.current = false;
    viewport.current.scrollTop = viewport.current.scrollHeight;
  }, [fixture, snapshot.loading, turns]);

  const loadOlder = async () => {
    const el = viewport.current;
    const prior = store.getSnapshot();
    if (!el || prior.loading || prior.loadingOlder || prior.before === null) return;
    const top = el.getBoundingClientRect().top;
    const anchor = Array.from(el.querySelectorAll<HTMLElement>("article")).find(
      (row) => row.getBoundingClientRect().bottom >= top,
    );
    const oldTop = anchor?.getBoundingClientRect().top;
    await store.loadOlder();
    if (!anchor || oldTop === undefined || store.getSnapshot().before === prior.before) return;
    requestAnimationFrame(() => {
      if (anchor.isConnected) el.scrollTop += anchor.getBoundingClientRect().top - oldTop;
    });
  };
  const jump = async (hit: TranscriptHit) => {
    if (!(await store.jumpToHit(hit))) return;
    select(hit);
    requestAnimationFrame(() =>
      viewport.current
        ?.querySelector(`[data-turn-key="${hit.pageEnd}:${hitTurn(hit)}"]`)
        ?.scrollIntoView({ block: "center" }),
    );
  };
  return (
    <main className="terminal-history-page">
      <div>
        <header className="terminal-history-header">
          <h1>{title}</h1>
          <label className="terminal-history-search">
            <input
              type="search"
              value={query}
              aria-label={strings.t("find.placeholder")}
              placeholder={strings.t("find.placeholder")}
              onChange={(event) => {
                select(undefined);
                void store.find(event.target.value);
              }}
            />
            <KeyHint keys="⌘F" className="terminal-history-search-key" aria-hidden="true" />
          </label>
        </header>
        {query && !fixture && (
          <nav className="terminal-history-results" aria-label={strings.t("find.placeholder")}>
            {snapshot.hits.map((hit, i) => (
              <button type="button" key={`${hit.pageEnd}-${hitTurn(hit)}-${i}`} onClick={() => void jump(hit)}>
                {hit.snippet}
              </button>
            ))}
            {snapshot.searching && <output>{strings.t("files.searching")}</output>}
            {!snapshot.searching && snapshot.searchComplete && !snapshot.hits.length && (
              <output>{strings.t("find.noResults")}</output>
            )}
            {!snapshot.searching && !snapshot.searchComplete && (
              <button type="button" onClick={() => void store.continueFind()}>
                {strings.t("find.next")}
              </button>
            )}
          </nav>
        )}
        {snapshot.error && !fixture && (
          <p className="terminal-history-error" role="alert">
            {snapshot.error}
          </p>
        )}
      </div>
      <div
        ref={viewport}
        className="terminal-history-scroll"
        onScroll={() => {
          if (viewport.current && viewport.current.scrollTop < 420) void loadOlder();
        }}
      >
        {snapshot.before !== null && !fixture && (
          <button
            type="button"
            className="terminal-history-older"
            disabled={snapshot.loadingOlder}
            onClick={() => void loadOlder()}
          >
            {strings.t(snapshot.loadingOlder ? "transcript.loadingOlder" : "inbox.earlier")}
          </button>
        )}
        {snapshot.loading && !fixture && (
          <output className="terminal-history-status">{strings.t("transcript.loading")}</output>
        )}
        {!snapshot.loading && !turns.length && (
          <p className="terminal-history-status">{strings.t("subagents.empty.title")}</p>
        )}
        {turns.map((turn, i) => {
          const key = turn.pageEnd !== undefined ? `${turn.pageEnd}:${turn.turnIndex}` : String(i);
          return (
            <Turn
              key={key}
              identity={key}
              turn={turn}
              store={store}
              strings={strings}
              highlighted={hitKeys.has(key)}
              rawOffset={
                selected?.role === "raw" && selected.rawStart === turn.raw?.start ? selected.rawOffset : undefined
              }
            />
          );
        })}
        {snapshot.hasNewer && !fixture && (
          <button
            type="button"
            className="terminal-history-older"
            onClick={() => {
              placeLatest.current = true;
              void store.returnToLatest();
            }}
          >
            {strings.t("transcript.jumpLatest")}
          </button>
        )}
      </div>
    </main>
  );
}

function Message({ text, at }: { text: string; at?: number }) {
  const literal = <p>{text}</p>;
  return isPromptMarkdown(text) ? (
    <Suspense fallback={literal}>
      <FormattedMessage text={text} at={at} />
    </Suspense>
  ) : (
    literal
  );
}

const Turn = memo(function Turn({
  identity,
  turn,
  store,
  strings,
  highlighted,
  rawOffset,
}: {
  identity: string;
  turn: TranscriptTurn;
  store: TerminalHistoryStore;
  strings: Strings;
  highlighted: boolean;
  rawOffset?: number;
}) {
  return (
    <article
      className={`terminal-history-turn${highlighted ? " is-highlighted" : ""}`}
      data-turn-key={identity}
      data-page-end={turn.pageEnd}
      data-source-turn={turn.turnIndex}
    >
      {turn.raw ? (
        <RawRecord store={store} strings={strings} section={turn.raw} matchOffset={rawOffset} />
      ) : (
        <>
          {(turn.prompt || turn.promptMore !== undefined) && (
            <section className="terminal-history-message terminal-history-message-user">
              <h2>{strings.t("transcript.you")}</h2>
              <Message text={turn.prompt} at={turn.promptAt} />
              {turn.promptMore !== undefined && (
                <button
                  type="button"
                  className="terminal-history-more"
                  onClick={() => void store.loadMore(turn, "user")}
                >
                  {strings.t("message.more")}
                </button>
              )}
            </section>
          )}
          {!!turn.tools.length && (
            <details className="terminal-history-tools">
              <summary>
                {turn.tools.length} {strings.t("ledger.total.tools")}
              </summary>
              <ul>
                {turn.tools.map((tool, i) => (
                  <li key={i}>{tool.title}</li>
                ))}
              </ul>
            </details>
          )}
          {(turn.answer || turn.answerMore !== undefined) && (
            <section className="terminal-history-message terminal-history-message-assistant">
              <h2>{strings.t("transcript.agent")}</h2>
              <Message text={turn.answer} at={turn.answerAt} />
              {turn.answerMore !== undefined && (
                <button
                  type="button"
                  className="terminal-history-more"
                  onClick={() => void store.loadMore(turn, "assistant")}
                >
                  {strings.t("message.more")}
                </button>
              )}
            </section>
          )}
        </>
      )}
    </article>
  );
});
