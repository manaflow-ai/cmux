// Settings > MCP Servers: the services the person connected for their agents (on a connect card in
// a chat, or by a Chief), from the Mac's one store of connections (SettingsMcpServers in the app,
// `optchat-chief integrations --json`). Each row says what it is, who has it and whether it works;
// Sign In opens the service's own sign-in page in a cmux tab and waits for the person; Remove asks
// once more, then forgets the server and its sign-in for every agent. The list is read when the
// page shows; nothing changes without a click.
import { useCallback, useEffect, useId, useState } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import { AgentMcpServers } from "./AgentMcpServers";
import type { McpServerRow, McpServersRun, McpServersState } from "../ops";
import { t } from "../strings";

/** How often the list is read while a sign-in waits for the person. */
const SIGN_IN_POLL_MS = 2000;

/** The status dot's tone for each state. */
const TONES = {
  connected: "success",
  signingIn: "attention",
  signInNeeded: "attention",
  failed: "attention",
  unknown: "neutral",
} as const;

/** The service's name as people say it: `linear` → `Linear`, `my_notes` → `My notes`. */
export function serverTitle(name: string): string {
  const words = name.replace(/_/g, " ");
  return words.charAt(0).toUpperCase() + words.slice(1);
}

function Row({
  row,
  busy,
  onRun,
}: {
  row: McpServerRow;
  busy: boolean;
  onRun: (action: Exclude<McpServersRun["action"], "refresh">) => void;
}) {
  const titleId = useId();
  const [confirming, setConfirming] = useState(false);
  const state = row.signingIn ? "signingIn" : row.state;
  const title = serverTitle(row.name);
  const confirmTitle = t("settingsWindow.mcpServers.removeTitle", title);
  const offersSignIn = row.kind === "remote" && row.state !== "connected";
  const details = [
    row.publisher && row.publisher !== "local" ? row.publisher : t("settingsWindow.mcpServers.onThisMac"),
    t(`settingsWindow.mcpServers.scope.${row.scope}`),
    row.state === "connected" && row.tools > 0 ? t("settingsWindow.mcpServers.tools", row.tools) : null,
  ].filter((part): part is string => !!part);
  return (
    <div className="row accounts-row" data-mcp-server={row.name} data-mcp-state={state}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {title}
          </div>
          <div className="row-help selectable">{details.join(" · ")}</div>
          <div className="row-help selectable font-mono">{row.address}</div>
          {row.state === "failed" && row.problem && (
            <div className="row-error selectable" data-mcp-problem="">
              {row.problem}
            </div>
          )}
          {row.signingIn && (
            <div className="row-help" data-mcp-waiting="">
              {t("settingsWindow.mcpServers.waiting")}
            </div>
          )}
          {row.error !== null && (
            <div className="row-error selectable" role="alert" data-mcp-error="">
              {row.error || t("settingsWindow.mcpServers.error.notFinished")}
            </div>
          )}
        </div>
        <span className="row-control keys-control">
          <span className="accounts-status devices-status" data-tone={TONES[state]} data-mcp-status="">
            <span className="accounts-dot" aria-hidden="true" />
            {t(`settingsWindow.mcpServers.state.${state}`)}
          </span>
          {offersSignIn && !confirming && (
            <Button
              className="button"
              data-mcp-action="signin"
              aria-describedby={titleId}
              disabled={busy}
              onClick={() => onRun("signin")}
            >
              {t(row.signingIn ? "settingsWindow.mcpServers.openPage" : "settingsWindow.mcpServers.signIn")}
            </Button>
          )}
          {!confirming && (
            <Button
              danger
              variant="ghost"
              className="button"
              data-mcp-action="remove"
              aria-label={t("settingsWindow.mcpServers.removeServer", title)}
              disabled={busy}
              onClick={() => setConfirming(true)}
            >
              {t("settingsWindow.mcpServers.remove")}
            </Button>
          )}
        </span>
      </div>
      {confirming && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="accounts-form" data-mcp-confirm="" role="group" aria-label={confirmTitle}>
          <div className="row-title">{confirmTitle}</div>
          <div className="row-help">{t("settingsWindow.mcpServers.removeBody")}</div>
          <div className="accounts-buttons">
            <Button
              danger
              variant="ghost"
              className="button"
              data-mcp-action="confirmRemove"
              disabled={busy}
              onClick={() => {
                setConfirming(false);
                onRun("remove");
              }}
            >
              {t("settingsWindow.mcpServers.remove")}
            </Button>
            <Button className="button" data-mcp-action="cancel" onClick={() => setConfirming(false)}>
              {t("settingsWindow.mcpServers.cancel")}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

export function McpServersCard() {
  const store = useStore();
  const [state, setState] = useState<McpServersState | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const refresh = useCallback(async () => {
    setState(await store.runMcpServers({ action: "refresh" }));
  }, [store]);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  // A sign-in finishes in the browser: read the list again until no row waits.
  const waiting = state?.servers.some((row) => row.signingIn) ?? false;
  useEffect(() => {
    if (!waiting) return;
    const timer = setInterval(() => void store.mcpServersState().then(setState), SIGN_IN_POLL_MS);
    return () => clearInterval(timer);
  }, [waiting, store]);
  const run = useCallback(
    (name: string, action: "signin" | "remove") => {
      setBusy(name);
      return store
        .runMcpServers({ action, name })
        .then(setState)
        .finally(() => setBusy(null));
    },
    [store],
  );
  return (
    <>
      <section className="group" data-card="mcpServers">
        <div className="group-title">{t("settingsWindow.mcpServers.title")}</div>
        <div className="row-help">{t("settingsWindow.mcpServers.help")}</div>
        <div className="row-help" data-mcp-connect-how="">
          {t("settingsWindow.mcpServers.connectHow")}
        </div>
        <div className="accounts-header">
          <Button
            type="button"
            className="button"
            data-mcp-action="refresh"
            disabled={state?.loading ?? false}
            onClick={() => void refresh()}
          >
            {t("settingsWindow.mcpServers.refresh")}
          </Button>
        </div>
        {state?.problem && (
          <div className="row-error" data-mcp-problem-page={state.problem}>
            {t(`settingsWindow.mcpServers.problem.${state.problem}`)}
          </div>
        )}
        {!state && (
          <div className="row-help" data-mcp-checking="">
            {t("settingsWindow.mcpServers.checking")}
          </div>
        )}
        {state && !state.problem && state.servers.length === 0 && (
          <div className="row-help" data-mcp-empty="">
            {t("settingsWindow.mcpServers.empty")}
          </div>
        )}
        {state && state.servers.length > 0 && (
          <div className="rows">
            {state.servers.map((row) => (
              <Row key={row.name} row={row} busy={busy !== null} onRun={(action) => void run(row.name, action)} />
            ))}
          </div>
        )}
      </section>
      {/* Claude Code and Codex, under cmux's own (Labs labs.agentCustomization; nothing while it is off). */}
      <AgentMcpServers />
    </>
  );
}
