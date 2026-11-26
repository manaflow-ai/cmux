// The chat's inline connect card (claudeConnect.ts), where the person already is: under the model
// picker after its Connect row, and in a Cloud chat's Set up Cloud card. The family's mark, one line,
// one button (`ClaudeConnect.begin`: the app signs in through cmux's browser and saves the result),
// and one progress line under it while that runs, with Cancel; an error keeps the line and offers Try
// again. Two quiet ways in sit behind disclosures, collapsed: Paste a token instead (Claude's setup
// token, `ClaudeConnect.add`) and Use an API key instead (`ClaudeConnect.addKey`). Both trim what was
// pasted before it goes to the host. The card goes once the host says a connection serves Cloud.
//
// Three looks share the parts (the gallery shows each): `card` (shipped) puts the progress line under
// the button; `row` is one compact line whose detail turns into the progress; `steps` adds a muted
// Step n of 3 caption (sign in, approve, save) above the line.
//
// An app connection (Settings > Integrations > Connections: Linear, Sentry, ...) draws through the same
// card with `provider` in place of `family` (its mark, name, line and button), a status `pill` in the
// head (shared/connect/ConnectPill.tsx), `details` under the line and `extra` controls after the
// button (Disconnect behind its confirm, a pasted-key form).
import { useId, useState, type FormEvent, type ReactNode } from "react";
import { AgentMark } from "../shared/AgentMark";
import { normalizeClaudeToken } from "../shared/claudeSetupToken";
import { checkToken, connectRequest, refusalText, type ConnectPhase, type ConnectProgress } from "./claudeConnect";
import { Check, Spinner } from "./conversation/icons";
import { useT } from "./i18n";
import "./claudeConnect.css";

export type ConnectCardLook = "card" | "row" | "steps";

export type ConnectCardFamily = "claude" | "codex";

/// An app connection's own parts, in place of a family's. `action` names the button in
/// `data-connect-action` (connect, reconnect, enable); else `begin`.
export type ConnectCardProvider = {
  mark: ReactNode;
  title: string;
  line: ReactNode;
  button: string;
  action?: string;
  disabled?: boolean;
};

const MARK = { claude: "claude", codex: "openai" } as const satisfies Record<ConnectCardFamily, string>;

const LINE = { claude: "connect.claude.line", codex: "connect.codex.line" } as const;
const BUTTON = { claude: "connect.claude.button", codex: "cloudSetup.chatgpt" } as const;
const PHASE = {
  claude: { starting: "connect.claude.starting", signing_in: "connect.claude.signingIn", saving: "connect.saving" },
  codex: { starting: "connect.claude.starting", signing_in: "connect.codex.signingIn", saving: "connect.saving" },
} as const satisfies Record<ConnectCardFamily, Record<ConnectPhase, string>>;
// Codex's browser sign-in has no "opening" step of its own: its first phase reads as signing in.
const CODEX_PHASE: Record<ConnectPhase, ConnectPhase> = {
  starting: "signing_in",
  signing_in: "signing_in",
  saving: "saving",
};
const STEP: Record<ConnectPhase, number> = { starting: 1, signing_in: 2, saving: 3 };

export function ConnectCard({
  family,
  look = "card",
  progress,
  done = false,
  onBegin,
  onCancel,
  onPaste,
  onApiKey,
  onDismiss,
  provider,
  pill,
  details,
  extra,
}: {
  /// The family the card signs in (Claude, Codex); an app connection passes `provider` instead.
  family?: ConnectCardFamily;
  provider?: ConnectCardProvider;
  /// The connection's status pill, trailing the head.
  pill?: ReactNode;
  /// Lines under the line (whose it is, when its sign-in lapses, why it is unavailable).
  details?: ReactNode;
  /// The host's own controls after the button.
  extra?: ReactNode;
  look?: ConnectCardLook;
  /// The host's sign-in: a phase while it runs, else the error it ended with (ConnectProgress).
  progress: ConnectProgress;
  /// Saved, and the host has not yet said a connection serves Cloud: the line says Connected.
  done?: boolean;
  /// The one button: starts the host's sign-in. A rejection is shown as the card's error. Absent:
  /// a host that can only take a pasted token; the card shows that field open.
  onBegin?(): void | Promise<void>;
  /// Cancel while it runs. Absent: no Cancel.
  onCancel?(): void;
  /// Paste a token instead (Claude only): the host checks and saves the trimmed token.
  onPaste?(token: string, label?: string): Promise<void>;
  /// Use an API key instead: the host saves the trimmed key.
  onApiKey?(key: string): Promise<void>;
  /// Not now, while nothing runs: closes the card.
  onDismiss?(): void;
}) {
  const t = useT();
  const line = provider ? provider.line : family && t(LINE[family]);
  const [refusal, setRefusal] = useState<string | null>(null);
  const shownPhase = progress.phase && family === "codex" ? CODEX_PHASE[progress.phase] : progress.phase;
  const running = !done && shownPhase !== null;
  const error = running || done ? null : (progress.error ?? refusal);
  const begin = () => {
    if (!onBegin) return;
    setRefusal(null);
    void Promise.resolve()
      .then(onBegin)
      .catch((failure: unknown) => setRefusal(refusalText(failure, t("picker.connectClaude.refused"))));
  };
  const status = done ? (
    <output className="acpmux-connect-card__status" data-state="done">
      <Check size={12} /> {t("picker.connectClaude.connected")}
    </output>
  ) : running && shownPhase ? (
    <output className="acpmux-connect-card__status" data-state="running" aria-busy="true">
      <Spinner size={12} loading />
      <span>{t(PHASE[family ?? "claude"][shownPhase])}</span>
    </output>
  ) : error ? (
    <output className="acpmux-connect-card__status" data-state="error" role="alert">
      {t("picker.connectClaude.failed", { reason: error })}
    </output>
  ) : null;
  const button = onBegin && !done && !running && (
    <button
      type="button"
      className="ui-button ui-btn acpmux-connect-card__button"
      data-variant={look === "row" ? "subtle" : "solid"}
      data-size="sm"
      data-connect-action={error ? "retry" : (provider?.action ?? "begin")}
      disabled={provider?.disabled}
      onClick={begin}
    >
      {error ? t("picker.tryAgain") : provider ? provider.button : family && t(BUTTON[family])}
    </button>
  );
  const cancel = running && onCancel && (
    <button
      type="button"
      className="ui-button ui-btn acpmux-connect-card__button"
      data-variant="ghost"
      data-size="sm"
      data-connect-action="cancel"
      onClick={() => onCancel()}
    >
      {t("picker.setup.cancel")}
    </button>
  );
  const dismiss = onDismiss && !running && !done && (
    <button
      type="button"
      className="ui-button ui-btn acpmux-connect-card__button"
      data-variant="ghost"
      data-size="sm"
      data-connect-action="dismiss"
      onClick={() => onDismiss()}
    >
      {t("harness.notNow")}
    </button>
  );
  const others = !done && !running && (onPaste || onApiKey) && (
    <div className="acpmux-connect-card__others">
      {onPaste && family === "claude" && <PasteField kind="token" open={!onBegin} onSave={onPaste} />}
      {onApiKey && <PasteField kind="key" onSave={(key) => onApiKey(key)} />}
    </div>
  );
  return (
    <section className="acpmux-connect-card" data-look={look} data-family={family} data-connect-card="">
      <div className="acpmux-connect-card__head">
        {provider
          ? provider.mark
          : family && <AgentMark agent={MARK[family]} size={look === "row" ? 14 : 16} reserve />}
        <span className="acpmux-connect-card__text">
          {provider && <span className="acpmux-connect-card__title">{provider.title}</span>}
          {look === "steps" && family && (
            <span className="acpmux-connect-card__step">
              {t("cloudSetup.steps.progress", { step: done ? 3 : shownPhase ? STEP[shownPhase] : 1, total: 3 })}
            </span>
          )}
          {look === "row" ? (
            (status ?? <span className="acpmux-connect-card__line">{line}</span>)
          ) : (
            <span className="acpmux-connect-card__line">{line}</span>
          )}
        </span>
        {pill}
        {look === "row" && (button || cancel)}
        {look === "row" && extra}
      </div>
      {details && <div className="acpmux-connect-card__details">{details}</div>}
      {look !== "row" && (
        <>
          {(button || cancel || dismiss || extra) && (
            <div className="acpmux-connect-card__actions">
              {button}
              {cancel}
              {dismiss}
              {extra}
            </div>
          )}
          {status}
        </>
      )}
      {others}
    </section>
  );
}

/// One collapsed disclosure with one field: a Claude setup token (checked as Settings checks it) or
/// an API key. The pasted value is trimmed (a token loses every whitespace, `normalizeClaudeToken`).
function PasteField({
  kind,
  open = false,
  onSave,
}: {
  kind: "token" | "key";
  open?: boolean;
  onSave(value: string, label?: string): Promise<void>;
}) {
  const t = useT();
  const id = useId();
  const [value, setValue] = useState("");
  const [pending, setPending] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const check = kind === "token" ? checkToken(value) : value.trim() ? "valid" : "empty";
  const summary = kind === "token" ? t("connect.pasteToken") : t("connect.apiKey");
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (check !== "valid" || pending) return;
    setPending(true);
    setRefusal(null);
    const clean = kind === "token" ? connectRequest(value, "").token : value.trim();
    onSave(clean).then(
      () => {
        setPending(false);
        setValue("");
      },
      (failure: unknown) => {
        setPending(false);
        setRefusal(refusalText(failure, t("picker.connectClaude.refused")));
      },
    );
  };
  return (
    <details className="acpmux-connect-card__disclosure" data-connect-paste={kind} open={open || undefined}>
      <summary>{summary}</summary>
      <form className="acpmux-connect-card__field" onSubmit={submit}>
        <input
          id={id}
          className="ui-input"
          type="password"
          name={kind}
          autoComplete="off"
          spellCheck={false}
          aria-label={kind === "token" ? summary : t("turn.signIn.keyLabel")}
          placeholder={kind === "token" ? "sk-ant-oat01-…" : t("turn.signIn.keyLabel")}
          value={value}
          disabled={pending}
          aria-invalid={check === "invalid" || undefined}
          onChange={(event) => setValue(event.currentTarget.value)}
          onPaste={(event) => {
            // A key pasted with a stray newline or space reads as typed without it.
            const text = event.clipboardData.getData("text");
            if (!text) return;
            event.preventDefault();
            setValue(kind === "token" ? normalizeClaudeToken(text) : text.trim());
          }}
        />
        <button
          type="submit"
          className="ui-button ui-btn"
          data-variant="subtle"
          data-size="sm"
          disabled={check !== "valid" || pending}
        >
          {t("turn.signIn.save")}
        </button>
      </form>
      {check === "invalid" && <span className="acpmux-connect-card__invalid">{t("picker.connectClaude.invalid")}</span>}
      {refusal && (
        <span className="acpmux-connect-card__invalid" role="alert">
          {t("picker.connectClaude.failed", { reason: refusal })}
        </span>
      )}
    </details>
  );
}
