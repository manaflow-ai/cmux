// Your asks (History > Your asks): every message the person typed into a chat on this machine,
// newest first, from acpmux's Ask ledger (`_acpmux/asks`, asksModel.ts). Each row is the ask's
// first line, when it was asked, the chat it went to (a click opens it, as History's own rows do),
// a chip per pull request whose body names the ask (a click opens it in a browser tab), and the
// status acpmux gives it: open, has a pull request, or merged. The page only renders; acpmux decides
// what an ask is and what links to it.
import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { age } from "../homeListsModel";
import { useT } from "../i18n";
import { AgentMark } from "../NewTabPage";
import { isOlderDaemon } from "../queue/queueModel";
import { ASKS_LIMIT, askLine, prLabel, readAsks, type Ask, type AsksReply } from "./asksModel";
import "./asks.css";

type State =
  | { phase: "loading" }
  | { phase: "ready"; reply: AsksReply; at: number }
  | { phase: "failed" }
  | { phase: "older" };

type Props = {
  /// `_acpmux/asks` with `params` (direct.ts `asks`).
  load(params: Record<string, unknown>): Promise<unknown>;
  /// Shows chat `sessionId` in this tab (App.tsx `selectSession`).
  openSession(sessionId: string): void;
  /// Opens a pull request's URL.
  openUrl(url: string): void;
  now?: number;
};

export function AsksScreen({ load, openSession, openUrl, now }: Props) {
  const t = useT();
  const [state, setState] = useState<State>({ phase: "loading" });
  const request = useRef(0);
  const loadRef = useRef(load);
  useEffect(() => {
    loadRef.current = load;
  }, [load]);

  const read = useCallback(() => {
    const id = ++request.current;
    loadRef.current({ limit: ASKS_LIMIT, view: "next" }).then(
      (value) => {
        if (id === request.current) setState({ phase: "ready", reply: readAsks(value), at: Date.now() });
      },
      (error: unknown) => {
        if (id === request.current) setState(isOlderDaemon(error) ? { phase: "older" } : { phase: "failed" });
      },
    );
  }, []);

  useEffect(() => {
    read();
    const requests = request;
    return () => {
      // A reply after the page left is dropped.
      requests.current++;
    };
  }, [read]);

  const asks = state.phase === "ready" ? state.reply.asks : [];
  // Ages are counted from when the list was read, so a render stays pure.
  const clock = now ?? (state.phase === "ready" ? state.at : 0);
  const status =
    state.phase === "older"
      ? t("asks.older")
      : state.phase === "failed"
        ? t("asks.failed")
        : state.phase === "loading"
          ? t("waiting.loading")
          : asks.length === 0
            ? t("asks.empty")
            : "";

  return (
    <div className="ask" data-loading={state.phase === "loading" || undefined}>
      {status && (
        <output className="ask-status">
          {status}
          {state.phase === "failed" && (
            <Button bare className="ask-link" onClick={read}>
              {t("ledger.retry")}
            </Button>
          )}
        </output>
      )}
      {asks.length > 0 && (
        <ul className="ask-rows" aria-label={t("asks.title")}>
          {asks.map((ask) => (
            <AskRow key={ask.id} ask={ask} now={clock} openSession={openSession} openUrl={openUrl} />
          ))}
        </ul>
      )}
    </div>
  );
}

function AskRow({
  ask,
  now,
  openSession,
  openUrl,
}: {
  ask: Ask;
  now: number;
  openSession(sessionId: string): void;
  openUrl(url: string): void;
}) {
  const t = useT();
  const when = age(ask.ts, now, t);
  const chat = ask.sessionTitle || t("asks.chat");
  return (
    <li className="ask-row" data-status={ask.status} data-kind={ask.kind}>
      <span className="ask-mark" aria-hidden>
        <AgentMark harness={ask.harness} />
      </span>
      <div className="ask-body">
        <div className="ask-line">
          <span className="ask-text">{askLine(ask)}</span>
          <span className="ask-state" data-status={ask.status}>
            {t(`asks.status.${ask.status}`)}
          </span>
          {when && (
            <time className="ask-age" dateTime={new Date(ask.ts).toISOString()}>
              {when}
            </time>
          )}
        </div>
        <div className="ask-sub">
          <Button
            bare
            className="ask-chat"
            aria-description={t("asks.openChat")}
            onClick={() => openSession(ask.sessionId)}
          >
            {chat}
          </Button>
          {ask.prs.map((pr) => (
            <Button bare key={pr.url} className="ask-pr" data-state={pr.state} onClick={() => openUrl(pr.url)}>
              {prLabel(pr)}
              <span className="ask-pr-state">{t(`asks.pr.${pr.state}`)}</span>
            </Button>
          ))}
          <span className="ask-id">{ask.id}</span>
        </div>
      </div>
    </li>
  );
}
