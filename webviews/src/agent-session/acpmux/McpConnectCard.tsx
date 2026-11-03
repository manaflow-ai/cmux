import React, { useState } from "react";
import { useT } from "./i18n";
import { MCP_SCOPES, type AcpmuxMcpCallAsk, type AcpmuxMcpConnectAsk, type AcpmuxMcpScope } from "./model";

/// What the connect card's buttons do; the page sends each to acpmux on the person's connection.
export type McpConnectActions = {
  answer(approve: boolean, scope?: AcpmuxMcpScope): void | Promise<unknown>;
  /// Opens the server's sign-in in a cmux browser tab.
  signIn(connectionId: string): void | Promise<unknown>;
  /// Gives a key server its key; resolves false when the server refused it.
  setKey(connectionId: string, key: string): Promise<boolean>;
  dismiss(): void;
};

const SCOPE_KEYS = {
  chat: "mcp.scope.chat",
  chief: "mcp.scope.chief",
  allChiefs: "mcp.scope.allChiefs",
  agents: "mcp.scope.agents",
  everywhere: "mcp.scope.everywhere",
} as const;

/// An agent's ask to connect an MCP server (plans/cmux-next/mcp-connect-DESIGN.md), among the
/// chat's asks above the composer: the checked facts (the exact address, who publishes it,
/// Verified or not), who gets it, Connect and Cancel; then Sign in or the key's private field, and
/// what connected. Only the person's click answers it; the agent never sees a key or token.
export function McpConnectCard({
  ask,
  agent,
  actions,
}: {
  ask: AcpmuxMcpConnectAsk;
  agent: string;
  actions: McpConnectActions;
}) {
  const t = useT();
  const [scope, setScope] = useState<AcpmuxMcpScope>(ask.proposedScope);
  const [key, setKey] = useState("");
  const [busy, setBusy] = useState(false);
  const [refused, setRefused] = useState(false);
  const run = (work: () => void | Promise<unknown>) => {
    if (busy) return;
    setBusy(true);
    void Promise.resolve(work()).then(
      () => setBusy(false),
      () => setBusy(false),
    );
  };
  const saveKey = (event: React.FormEvent) => {
    event.preventDefault();
    if (!key || busy || !ask.connectionId) return;
    const sent = key;
    const id = ask.connectionId;
    setKey("");
    setRefused(false);
    setBusy(true);
    void actions.setKey(id, sent).then(
      (ok) => {
        setBusy(false);
        if (!ok) {
          setRefused(true);
          setKey((current) => current || sent);
        }
      },
      () => {
        setBusy(false);
        setRefused(true);
        setKey((current) => current || sent);
      },
    );
  };
  return (
    <div className="acpmux-secret-card acpmux-mcp-card" aria-live="polite" data-phase={ask.phase}>
      <div className="acpmux-secret-card-text">
        <span className="acpmux-secret-card-ask">{t("mcp.connect.ask", { agent, title: ask.title })}</span>
        {ask.reason && <span className="acpmux-secret-card-reason">{ask.reason}</span>}
        <span className="acpmux-mcp-card-target">{ask.target}</span>
        <span className={ask.verified ? "acpmux-mcp-card-verified" : "acpmux-mcp-card-unverified"}>
          {ask.verified
            ? t("mcp.connect.verified", { publisher: ask.publisher })
            : t("mcp.connect.unverified", { publisher: ask.publisher })}
        </span>
        <span className="acpmux-secret-card-private">{t("mcp.connect.private")}</span>
      </div>
      {ask.phase === "ask" && (
        <div className="acpmux-secret-card-row">
          <select
            className="acpmux-mcp-card-scope"
            aria-label={t("mcp.connect.scope")}
            value={scope}
            onChange={(event) => setScope(event.target.value as AcpmuxMcpScope)}
          >
            {MCP_SCOPES.map((s) => (
              <option key={s} value={s}>
                {t(SCOPE_KEYS[s])}
              </option>
            ))}
          </select>
          <button
            type="button"
            className="acpmux-secret-card-action"
            disabled={busy}
            onClick={() => run(() => actions.answer(true, scope))}
          >
            {t("mcp.connect.connect")}
          </button>
          <button
            type="button"
            className="acpmux-secret-card-action"
            disabled={busy}
            onClick={() => run(() => actions.answer(false))}
          >
            {t("mcp.connect.cancel")}
          </button>
        </div>
      )}
      {ask.phase === "connecting" && <span className="acpmux-mcp-card-status">{t("mcp.connect.connecting")}</span>}
      {ask.phase === "signIn" && ask.connectionId && (
        <div className="acpmux-secret-card-row">
          <button
            type="button"
            className="acpmux-secret-card-action"
            disabled={busy}
            onClick={() => run(() => actions.signIn(ask.connectionId ?? ""))}
          >
            {t("mcp.connect.signIn", { title: ask.title })}
          </button>
        </div>
      )}
      {ask.phase === "key" && ask.connectionId && (
        <form className="acpmux-secret-card-row" onSubmit={saveKey}>
          <input
            className="acpmux-secret-card-field"
            type="password"
            autoComplete="off"
            spellCheck={false}
            aria-label={t("mcp.connect.key", { title: ask.title })}
            placeholder={t("mcp.connect.key", { title: ask.title })}
            value={key}
            aria-invalid={refused}
            onChange={(event) => {
              setRefused(false);
              setKey(event.target.value);
            }}
          />
          <button type="submit" className="acpmux-secret-card-action" disabled={!key || busy}>
            {t("mcp.connect.saveKey")}
          </button>
        </form>
      )}
      {(ask.phase === "connected" || ask.phase === "failed") && (
        <div className="acpmux-secret-card-row">
          <span className="acpmux-mcp-card-status">
            {ask.phase === "connected"
              ? t("mcp.connect.connected", { title: ask.title, count: ask.tools ?? 0 })
              : t("mcp.connect.failed", { title: ask.title })}
          </span>
          <button type="button" className="acpmux-secret-card-action" onClick={() => actions.dismiss()}>
            {t("mcp.connect.dismiss")}
          </button>
        </div>
      )}
    </div>
  );
}

/// A connected server's tool that waits for the person: the tool, its arguments, Run once,
/// Always allow, Decline.
export function McpCallCard({
  ask,
  onAnswer,
}: {
  ask: AcpmuxMcpCallAsk;
  onAnswer(approve: boolean, always: boolean): void | Promise<unknown>;
}) {
  const t = useT();
  return (
    <div className="acpmux-secret-card acpmux-mcp-call-card" aria-live="polite">
      <div className="acpmux-secret-card-text">
        <span className="acpmux-secret-card-ask">{t("mcp.call.ask", { tool: ask.tool, title: ask.title })}</span>
        {ask.arguments && <code className="acpmux-mcp-card-arguments">{ask.arguments}</code>}
      </div>
      <div className="acpmux-secret-card-row">
        <button type="button" className="acpmux-secret-card-action" onClick={() => onAnswer(true, false)}>
          {t("mcp.call.once")}
        </button>
        <button type="button" className="acpmux-secret-card-action" onClick={() => onAnswer(true, true)}>
          {t("mcp.call.always")}
        </button>
        <button type="button" className="acpmux-secret-card-action" onClick={() => onAnswer(false, false)}>
          {t("mcp.call.decline")}
        </button>
      </div>
    </div>
  );
}
