import { useEffect, useId, useState } from "react";
import { isClaudeToken, normalizeClaudeToken } from "../../../agent-session/shared/claudeSetupToken";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import type { ClaudeTokenPhase, ClaudeTokenState } from "../ops";
import { t } from "../strings";
import { ConnectionError } from "./ModelConnectionFields";
import type { Run } from "./modelConnections";

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

export function ClaudeSetupTokenForm({
  state,
  unavailable,
  busy,
  run,
  error,
  onDone,
  onCancel,
}: {
  state: ClaudeTokenState | undefined;
  unavailable?: string;
  busy: boolean;
  run: Run;
  error: string | null;
  onDone(): void;
  onCancel(): void;
}) {
  const claude = state ?? CLAUDE_IDLE;
  const running = !!(claude.attempt || claude.phase);
  // Done: a run this form saw ended with its token saved (the host's `saved`; a Cancel is not).
  const [seen, setSeen] = useState(false);
  if (running && !seen) setSeen(true);
  const saved = seen && !running && claude.error === null && claude.saved === true;
  useEffect(() => {
    if (saved) onDone();
  }, [saved, onDone]);
  return (
    <div className="accounts-form" data-models-claude-token="">
      <p className="row-help">{t("settingsWindow.models.claude.help")}</p>
      {running || claude.error ? (
        <ClaudeTokenStatus claude={claude} busy={busy || !!unavailable} run={run} />
      ) : (
        <div className="accounts-buttons">
          <Button
            type="button"
            className="button"
            variant="solid"
            data-models-action="connectClaudeToken"
            disabled={busy || !!unavailable}
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
      <details className="models-claude-paste" data-models-claude-paste="">
        <summary className="row-help">{t("connect.pasteToken")}</summary>
        <ClaudeTokenForm busy={busy || running} run={run} onDone={onDone} onCancel={onCancel} />
      </details>
    </div>
  );
}

/** Paste a token instead: the token `claude setup-token` prints, with an optional label. The token
 * leaves the page's state before it is sent. */
export function ClaudeTokenForm({
  busy,
  run,
  replacement,
  error,
  onDone,
  onCancel,
}: {
  busy: boolean;
  run: Run;
  replacement?: { id: string; instance: string; label: string };
  error?: string | null;
  onDone(): void;
  onCancel(): void;
}) {
  const labelId = useId();
  const [token, setToken] = useState("");
  const [label, setLabel] = useState(replacement?.label ?? "");
  const pasted = normalizeClaudeToken(token);
  const valid = isClaudeToken(pasted);
  const send = () => {
    if (!valid || busy) return;
    const named = label.trim();
    setToken("");
    void run({
      action: "addClaudeToken",
      token: pasted,
      ...(named ? { label: named } : {}),
      ...(replacement ? { replacement: { id: replacement.id, instance: replacement.instance } } : {}),
    }).then((ok) => ok && onDone());
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
      {error && <ConnectionError>{error}</ConnectionError>}
      <div className="accounts-buttons">
        <Button type="submit" className="button" data-models-action="addClaudeToken" disabled={busy || !valid}>
          {t(replacement ? "settingsWindow.models.org.replace" : "settingsWindow.models.claude.add")}
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
