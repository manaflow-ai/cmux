import { useEffect, useId, useRef, useState, type RefObject } from "react";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { isClaudeToken, normalizeClaudeToken } from "../../../agent-session/shared/claudeSetupToken";
import { Button } from "../../../ui/Button";
import { Dialog, DialogTitle } from "../../../ui/Dialog";
import { Input } from "../../../ui/Input";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { Icon } from "../icons";
import { revealRow } from "../keyboard";
import type { ClaudeTokenPhase, ClaudeTokenState, ModelConnection, ModelsState } from "../ops";
import { providerById, providerName } from "../providerCatalog";
import { t } from "../strings";
import { sharedModelKeyName } from "./ModelsTeamSections";
import { chatgptErrorText, tokenTimeRemaining, type Run, type SetupSelection } from "./modelConnections";

const cloudRows = ["claude", "chatgpt", "apiKey"] as const;
type CloudRow = (typeof cloudRows)[number];
const rowNames = { claude: "Claude", chatgpt: "ChatGPT" } as const;
const keyProviders = ["anthropic", "openai"] as const;

export function cloudReadiness(
  models: ModelsState,
  row: CloudRow,
  connections = models.personal.connections,
  canLaunch: (connection: ModelConnection) => boolean = () => true,
) {
  const family = row === "claude" ? "claude" : "codex";
  const candidates = connections.filter(
    (c) =>
      c.servesCloud && (row === "apiKey" ? c.kind === "api-key" : (c.cloudFamilies ?? c.families).includes(family)),
  );
  const ready = candidates.find(
    (c) => c.enabled && c.signedIn && tokenTimeRemaining(c, Date.now()) > 0 && canLaunch(c),
  );
  if (ready) return { state: "ready", via: ready.label, connection: ready } as const;
  const team =
    models.organization.team &&
    models.organization.keys.find((key) => key.set && (row === "apiKey" || key.agent === family));
  if (team) return { state: "ready", via: sharedModelKeyName(team.agent), connection: null } as const;
  const first = candidates[0];
  return first
    ? ({ state: "off", via: first.label, connection: first } as const)
    : ({ state: "missing", via: null, connection: null } as const);
}

export function CloudModelOverview({
  models,
  connections,
  canLaunch,
  focus,
  busy,
  run,
  onPasteToken,
  onSetup,
  onDisconnect,
}: {
  models: ModelsState;
  connections: ModelConnection[];
  canLaunch(connection: ModelConnection): boolean;
  focus: string | null;
  busy: boolean;
  run: Run;
  onPasteToken(trigger: HTMLElement): void;
  onSetup(selection: SetupSelection, trigger: HTMLElement | null): void;
  onDisconnect(connection: ModelConnection, trigger: HTMLElement | null): void;
}) {
  return cloudRows.map((row) => (
    <CloudModelRow
      key={row}
      row={row}
      models={models}
      readiness={cloudReadiness(models, row, connections, canLaunch)}
      focused={focus === `cloud.${row}`}
      busy={busy}
      run={run}
      onPasteToken={onPasteToken}
      onSetup={onSetup}
      onDisconnect={onDisconnect}
    />
  ));
}

function CloudModelRow({
  row,
  models,
  readiness,
  focused,
  busy,
  run,
  onPasteToken,
  onSetup,
  onDisconnect,
}: {
  row: CloudRow;
  models: ModelsState;
  readiness: ReturnType<typeof cloudReadiness>;
  focused: boolean;
  busy: boolean;
  run: Run;
  onPasteToken(trigger: HTMLElement): void;
  onSetup(selection: SetupSelection, trigger: HTMLElement | null): void;
  onDisconnect(connection: ModelConnection, trigger: HTMLElement | null): void;
}) {
  const { state, via, connection } = readiness;
  const title = row === "apiKey" ? t("settingsWindow.harnesses.accounts.apiKey") : rowNames[row];
  const off = state === "off" && connection.signedIn && !connection.enabled;
  const signedOut = state === "off" && !connection.signedIn;
  const setup = state === "missing" || signedOut;
  const managedKey = row === "apiKey" && connection?.credentialInstance ? connection : null;
  const claude = claudeTokenOf(models);
  const tokenRunning = claude.attempt !== null || claude.phase !== null;
  const keyMenu = useRef<HTMLButtonElement>(null);
  const signIn = () => void run({ action: "connectChatGPT" });
  const chatgptPending = models.chatgpt.attempt !== null || models.chatgpt.error !== null;
  const chatgptDeviceBusy =
    models.chatgptDevice?.phase === "starting" ||
    models.chatgptDevice?.phase === "waiting" ||
    models.chatgptDevice?.phase === "cancelling";
  const status =
    state === "ready"
      ? t("settingsWindow.cloud.status.ready")
      : signedOut
        ? t("settingsWindow.harnesses.signedOut")
        : off
          ? t("settingsWindow.cloud.status.turnedOff")
          : t("settingsWindow.cloud.status.missing");
  return (
    <div
      className="row accounts-row"
      tabIndex={-1}
      ref={focused ? revealRow : undefined}
      data-cloud-row={row}
      data-cloud-status={state}
    >
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          {row === "apiKey" ? (
            <Icon name="lock" />
          ) : (
            <AgentMark agent={row === "claude" ? "claude" : "openai"} size={16} />
          )}
        </span>
        <div className="row-label">
          <div className="row-title">{title}</div>
          <div className="row-help" data-cloud-status-text="">
            {status}
          </div>
          {via && (
            <div className="row-help selectable" data-cloud-via="">
              {via}
            </div>
          )}
        </div>
        <div className="accounts-buttons">
          {off && (
            <Button
              className="button"
              variant="solid"
              data-cloud-action="turnOn"
              disabled={busy}
              onClick={() => void run({ action: "enable", id: connection.id, on: true })}
            >
              {t("settingsWindow.cloud.turnOn")}
            </Button>
          )}
          {setup && row === "claude" && !tokenRunning && !claude.error && (
            <Button
              className="button"
              variant="solid"
              data-cloud-action="connectClaudeToken"
              disabled={busy}
              onClick={() => void run({ action: "connectClaudeToken" })}
            >
              {t("connect.claude.button")}
            </Button>
          )}
          {setup && row === "chatgpt" && !chatgptPending && (
            <Button
              className="button"
              variant="solid"
              data-cloud-action="connectChatGPT"
              disabled={busy || chatgptDeviceBusy}
              onClick={(event) => {
                const target = connection?.kind === "chatgpt-plan" ? connection.id : undefined;
                if (target) {
                  onSetup({ id: "chatgpt", target }, event.currentTarget);
                  return;
                }
                signIn();
              }}
            >
              {t("settingsWindow.cloud.chatgpt.signIn")}
            </Button>
          )}
          {row === "apiKey" && (setup || managedKey) && (
            <Menu
              key={
                managedKey ? `${managedKey.id}:${managedKey.credentialInstance}:${managedKey.keyRevision ?? ""}` : "add"
              }
            >
              <MenuButton
                className="button"
                buttonRef={keyMenu}
                label={
                  managedKey ? t("settingsWindow.models.more", managedKey.label) : t("settingsWindow.cloud.apiKey.add")
                }
                data-menu={managedKey ? `cloud-connection-${managedKey.id}` : "cloud-api-key"}
                disabled={busy}
              >
                {managedKey ? <Icon name="ellipsis" /> : t("settingsWindow.cloud.apiKey.add")}
              </MenuButton>
              <MenuPopup align="end">
                {managedKey ? (
                  <>
                    {managedKey.canReplaceKey && (
                      <MenuItem
                        data-value="replace"
                        onSelect={() =>
                          onSetup({ id: managedKey.provider, target: managedKey.id, edit: managedKey }, keyMenu.current)
                        }
                      >
                        {t("settingsWindow.models.org.replace")}
                      </MenuItem>
                    )}
                    <MenuItem data-value="remove" onSelect={() => onDisconnect(managedKey, keyMenu.current)}>
                      {t("settingsWindow.models.disconnect")}
                    </MenuItem>
                  </>
                ) : (
                  keyProviders.map((id) => (
                    <MenuItem key={id} data-value={id} onSelect={() => onSetup({ id }, keyMenu.current)}>
                      {providerName(providerById(id)!)}
                    </MenuItem>
                  ))
                )}
              </MenuPopup>
            </Menu>
          )}
        </div>
      </div>
      {row === "claude" && (setup || tokenRunning) && (
        <div className="accounts-body">
          <ClaudeTokenStatus claude={claude} busy={busy} run={run} />
          {setup && !tokenRunning && (
            <Button
              className="button"
              variant="ghost"
              data-cloud-action="setUpClaude"
              disabled={busy}
              onClick={(event) => onPasteToken(event.currentTarget)}
            >
              {t("connect.pasteToken")}
            </Button>
          )}
        </div>
      )}
      {row === "chatgpt" && chatgptPending && (
        <div className="accounts-body">
          <ChatGPTStatus chatgpt={models.chatgpt} busy={busy} run={run} onRetry={signIn} />
        </div>
      )}
    </div>
  );
}

export function ChatGPTStatus({
  chatgpt,
  busy,
  run,
  onRetry,
}: {
  chatgpt: ModelsState["chatgpt"];
  busy: boolean;
  run: Run;
  onRetry(): void;
}) {
  if (chatgpt.attempt) {
    return (
      <output className="models-chatgpt" data-chatgpt="pending">
        <span className="row-help">{t("connect.codex.signingIn")}</span>
        <Button
          className="button"
          data-models-action="cancelChatGPT"
          disabled={busy}
          onClick={() => void run({ action: "cancelChatGPT" })}
        >
          {t("settingsWindow.cancel")}
        </Button>
      </output>
    );
  }
  if (chatgpt.error) {
    return (
      <div className="models-chatgpt" data-chatgpt="error">
        <span className="row-error" role="alert">
          {chatgptErrorText(chatgpt.error)}
        </span>
        <Button className="button" data-models-action="retryChatGPT" disabled={busy} onClick={onRetry}>
          {t("settingsWindow.models.tryAgain")}
        </Button>
      </div>
    );
  }
  return null;
}

export function ClaudeTokenDialog({
  models,
  busy,
  error,
  run,
  pasteOpen,
  returnFocus,
  onClose,
  onCancel,
}: {
  models: ModelsState;
  busy: boolean;
  error: string | null;
  run: Run;
  pasteOpen: boolean;
  returnFocus: RefObject<HTMLElement | null>;
  onClose(): void;
  onCancel(): void;
}) {
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onCancel();
      }}
      className="models-dialog ui-glass ui-glass-floats"
      backdropClassName="models-dialog-backdrop"
      finalFocus={returnFocus}
    >
      <div className="models-dialog-content" data-models-dialog="claude-token">
        <div className="models-dialog-heading">
          <DialogTitle>{t("settingsWindow.models.claude.title")}</DialogTitle>
        </div>
        <Button
          className="models-dialog-close"
          variant="ghost"
          size="sm"
          icon
          aria-label={t("settingsWindow.studio.close")}
          onClick={onCancel}
        >
          <Icon name="xmark" />
        </Button>
        <ClaudeConnectForm
          claude={claudeTokenOf(models)}
          pasteOpen={pasteOpen}
          busy={busy}
          run={run}
          error={error}
          onDone={onClose}
          onCancel={onCancel}
        />
      </div>
    </Dialog>
  );
}

const CLAUDE_IDLE: ClaudeTokenState = { attempt: null, phase: null, error: null };

/** Connect Claude's progress line per phase (the one-click run, ops.ts `claudeToken`). */
const CLAUDE_PHASES: Record<ClaudeTokenPhase, string> = {
  starting: "connect.claude.starting",
  signing_in: "connect.claude.signingIn",
  saving: "connect.saving",
};

/** Connect Claude's run, under its button: the phase's line with Cancel, or the last run's error with
 * Try Again. Nothing once it is saved: the new connection's row says so. */
function ClaudeTokenStatus({ claude, busy, run }: { claude: ClaudeTokenState; busy: boolean; run: Run }) {
  if (claude.attempt || claude.phase) {
    const phase = claude.phase ?? "starting";
    return (
      <output className="models-chatgpt" data-claude-token={phase} aria-busy="true">
        <span className="row-help">{t(CLAUDE_PHASES[phase])}</span>
        <Button
          type="button"
          className="button"
          data-models-action="cancelClaudeToken"
          disabled={busy}
          onClick={() => void run({ action: "cancelClaudeToken" })}
        >
          {t("settingsWindow.cancel")}
        </Button>
      </output>
    );
  }
  if (claude.error) {
    return (
      <div className="models-chatgpt" data-claude-token="error">
        <span className="row-error" role="alert">
          {claude.error}
        </span>
        <Button
          type="button"
          className="button"
          data-models-action="retryClaudeToken"
          disabled={busy}
          onClick={() => void run({ action: "connectClaudeToken" })}
        >
          {t("settingsWindow.models.tryAgain")}
        </Button>
      </div>
    );
  }
  return null;
}

/** The page's Connect Claude run: `models.claudeToken`, idle on a host that omits it. */
const claudeTokenOf = (models: ModelsState): ClaudeTokenState => models.claudeToken ?? CLAUDE_IDLE;

function ClaudeConnectForm({
  claude,
  pasteOpen = false,
  busy,
  run,
  error,
  onDone,
  onCancel,
}: {
  claude: ClaudeTokenState;
  /** Settings > Cloud's Paste a token instead opens the disclosure. */
  pasteOpen?: boolean;
  busy: boolean;
  run: Run;
  error: string | null;
  onDone(): void;
  onCancel(): void;
}) {
  const running = claude.attempt !== null || claude.phase !== null;
  // Done: a run this form saw ended with its token saved (the host's `saved`; a Cancel is not).
  const [seen, setSeen] = useState(false);
  if (running && !seen) setSeen(true);
  const saved = seen && !running && claude.error === null && claude.saved === true;
  useEffect(() => {
    if (saved) onDone();
  }, [saved, onDone]);
  return (
    <div className="accounts-form" data-models-way="claude" data-models-claude-form="">
      <p className="row-help">{t("settingsWindow.models.claude.help")}</p>
      {running || claude.error ? (
        <ClaudeTokenStatus claude={claude} busy={busy} run={run} />
      ) : (
        <div className="accounts-buttons">
          <Button
            type="button"
            className="button"
            variant="solid"
            data-models-action="connectClaudeToken"
            disabled={busy}
            onClick={() => void run({ action: "connectClaudeToken" })}
          >
            {t("connect.claude.button")}
          </Button>
        </div>
      )}
      {error && !claude.error && (
        <p className="row-error" role="alert">
          {error}
        </p>
      )}
      <details className="models-claude-paste" data-models-claude-paste="" open={pasteOpen}>
        <summary className="row-help">{t("connect.pasteToken")}</summary>
        <ClaudeTokenForm busy={busy || running} run={run} onDone={onDone} onCancel={onCancel} />
      </details>
    </div>
  );
}

/** Paste a token instead: the token `claude setup-token` prints, with an optional label. The token
 * leaves the page's state before it is sent. */
function ClaudeTokenForm({
  busy,
  run,
  onDone,
  onCancel,
}: {
  busy: boolean;
  run: Run;
  onDone(): void;
  onCancel(): void;
}) {
  const labelId = useId();
  const [token, setToken] = useState("");
  const [label, setLabel] = useState("");
  const pasted = normalizeClaudeToken(token);
  const valid = isClaudeToken(pasted);
  const send = () => {
    if (!valid || busy) return;
    const named = label.trim();
    setToken("");
    void run(
      named ? { action: "addClaudeToken", token: pasted, label: named } : { action: "addClaudeToken", token: pasted },
    ).then((ok) => ok && onDone());
  };
  return (
    <form
      className="accounts-form"
      data-models-claude-paste-form=""
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      <Input
        className="field"
        type="password"
        aria-label={t("connect.pasteToken")}
        autoComplete="off"
        spellCheck={false}
        maxLength={4096}
        value={token}
        disabled={busy}
        onChange={(event) => setToken(normalizeClaudeToken(event.target.value))}
      />
      {pasted !== "" && !valid && (
        <p className="row-error" role="alert" data-claude-token-invalid="">
          {t("settingsWindow.models.claude.invalid")}
        </p>
      )}
      <label className="row-help" id={labelId}>
        {t("settingsWindow.models.key.label")}
      </label>
      <Input
        className="field"
        aria-labelledby={labelId}
        autoComplete="off"
        maxLength={128}
        placeholder="Claude Code"
        value={label}
        disabled={busy}
        onChange={(event) => setLabel(event.target.value)}
      />
      <div className="accounts-buttons">
        <Button type="submit" className="button" data-models-action="addClaudeToken" disabled={busy || !valid}>
          {t("settingsWindow.models.claude.add")}
        </Button>
        <Button
          type="button"
          className="button"
          onClick={() => {
            setToken("");
            onCancel();
          }}
        >
          {t("settingsWindow.cancel")}
        </Button>
      </div>
    </form>
  );
}
