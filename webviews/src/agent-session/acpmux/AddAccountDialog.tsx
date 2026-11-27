import { useId, useRef, useState } from "react";
import { ChoiceGroup } from "../../ui/ChoiceGroup";
import { Dialog } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import { CLAUDE_SETUP_TOKEN_COMMAND, normalizeClaudeToken } from "../shared/claudeSetupToken";
import type { NewChatAccount } from "./chatAccounts";
import { checkToken } from "./claudeConnect";
import { CopyButton } from "./conversation/CopyButton";
import { useT, type StringKey } from "./i18n";
import "./addAccount.css";
import "./claudeConnect.css";
import { accountIdFor } from "./addAccountDialogModel";

type Kind = "direct-subscription" | "direct-api-key";
/** new: a fresh login folder of its own; cli: the CLI's own login on this Mac; token: a Claude setup
 * token (`claude setup-token`, Claude only); key: an API key. */
type Way = "new" | "cli" | "token" | "key";

/** The kind acpmux gives a Claude setup token's account (routes.rs `RouteKind::ClaudeToken`): the host
 * checks the token, keeps it in the Keychain and hands acpmux only its reference (cmux#59852). */
export const CLAUDE_TOKEN_KIND = "claude-token";

const TOKEN_PLACEHOLDER = "sk-ant-oat01-…";

/** The families whose CLI keeps its login in a folder a second account can have its own copy of. */
const BRANDS: Record<string, { brand: StringKey; cli: StringKey; folder: string }> = {
  claude: { brand: "picker.addBrand.claude", cli: "picker.addCli.claude", folder: "~/.claude" },
  codex: { brand: "picker.addBrand.codex", cli: "picker.addCli.codex", folder: "~/.codex" },
};

/** The picker adds a local route. Rust validates it; existing accounts and bindings stay intact.
 * Nobody types an id or a folder: the id comes from the name, and a new login gets its own folder
 * under ~/.cmux/accounts (the native host expands `~/`). */
export function AddAccountDialog({
  add,
  family,
  kinds = ["direct-subscription", "direct-api-key"],
  existing = [],
  initialWay,
  onClose,
  onAdded,
}: {
  add(account: NewChatAccount): Promise<void>;
  family: string;
  kinds?: Kind[];
  /** The ids of the routes there are, so a new one never asks to replace one. */
  existing?: readonly string[];
  /** The way the sheet opens on, when it is one of the family's (the gallery's states). */
  initialWay?: Way;
  onClose(): void;
  onAdded(): void;
}) {
  const t = useT();
  const group = useId();
  const known = BRANDS[family];
  const ways: Way[] = [
    ...(kinds.includes("direct-subscription") ? (known ? (["new", "cli"] as const) : (["cli"] as const)) : []),
    // Claude's long-lived token from `claude setup-token`, the same one Settings > Cloud takes.
    ...(kinds.includes("direct-subscription") && family === "claude" ? (["token"] as const) : []),
    ...(kinds.includes("direct-api-key") ? (["key"] as const) : []),
  ];
  const [way, setWay] = useState<Way>(initialWay && ways.includes(initialWay) ? initialWay : (ways[0] ?? "key"));
  const [name, setName] = useState("");
  const [secret, setSecret] = useState("");
  const [token, setToken] = useState("");
  const [pending, setPending] = useState(false);
  const sending = useRef(false);
  const [error, setError] = useState<string>();
  const brand = known ? t(known.brand) : family;
  // The family's own name for a CLI cmux has no product name for ("gemini login"), never the
  // generic "CLI login", which the sentences around it would double ("the CLI login login").
  const cli = known ? t(known.cli) : family;
  // A second login is "ChatGPT 2", then 3, ...: the first number no route has taken.
  const nextName = () => {
    for (let n = 2; ; n++) {
      const candidate = t("picker.addName.new", { brand, n });
      if (accountIdFor(candidate, family, existing) === accountIdFor(candidate, family, [])) return candidate;
    }
  };
  const defaultName =
    way === "new"
      ? nextName()
      : way === "cli"
        ? t("picker.addName.cli", { cli })
        : way === "token"
          ? t("picker.addName.token")
          : t("picker.addName.key", { brand });
  const id = accountIdFor(name.trim(), defaultName, existing);
  const folder = `~/.cmux/accounts/${id}`;
  const choices: { way: Way; title: string; detail: string }[] = ways.map((value) =>
    value === "new"
      ? { way: value, title: t("picker.addWay.new", { brand }), detail: t("picker.addWay.newDetail", { folder }) }
      : value === "cli"
        ? {
            way: value,
            title: t("picker.addWay.cli", { cli }),
            detail: known ? t("picker.addWay.cliDetail", { folder: known.folder }) : t("picker.addWay.cliDetailAny"),
          }
        : value === "token"
          ? { way: value, title: t("picker.addWay.token"), detail: t("picker.addWay.tokenDetail") }
          : { way: value, title: t("picker.addWay.key"), detail: t("picker.addWay.keyDetail") },
  );
  const tokenCheck = checkToken(token);
  const ready = way === "key" ? !!secret.trim() : way === "token" ? tokenCheck === "valid" : true;
  const submit = () => {
    if (sending.current || !ready) return;
    const account: NewChatAccount = {
      id,
      kind: way === "key" ? "direct-api-key" : way === "token" ? CLAUDE_TOKEN_KIND : "direct-subscription",
      family,
      name: name.trim() || defaultName,
    };
    if (way === "new") account.accountHome = folder;
    // A second ChatGPT login shares the CLI's conversations, so routing can move a chat onto it.
    if (way === "new" && family === "codex") account.shadow = true;
    if (way === "key") account.secret = secret.trim();
    // Every whitespace character out: a terminal that wrapped or padded the token gives back the one it printed.
    if (way === "token") account.secret = normalizeClaudeToken(token);
    sending.current = true;
    setPending(true);
    setError(undefined);
    // Invoke in the submit's turn so the native one-use gesture still belongs to this request.
    void add(account).then(onAdded, (failure: unknown) => {
      sending.current = false;
      setPending(false);
      setError(
        t("environment.saveFailed", { reason: failure instanceof Error ? failure.message : t("picker.accountFailed") }),
      );
    });
  };
  const title = known ? t("picker.addTitle", { brand }) : t("picker.addAccount");
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !pending) onClose();
      }}
      label={title}
      className="ui-glass ui-glass-floats acpmux-add-account"
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          submit();
        }}
      >
        <header>
          <h2>{title}</h2>
          <p>{t("picker.addLead")}</p>
        </header>
        {choices.length > 1 && (
          <ChoiceGroup
            label={t("picker.accountKind")}
            className="acpmux-add-account-ways"
            busy={pending}
            onSubmit={submit}
            onCancel={() => {
              if (!pending) onClose();
            }}
          >
            {choices.map((choice) => (
              <label
                key={choice.way}
                className="acpmux-add-account-way"
                htmlFor={`${group}-${choice.way}`}
                aria-label={choice.title}
              >
                <input
                  id={`${group}-${choice.way}`}
                  aria-label={choice.title}
                  aria-describedby={`${group}-${choice.way}-detail`}
                  type="radio"
                  name={group}
                  value={choice.way}
                  checked={choice.way === way}
                  disabled={pending}
                  onChange={() => setWay(choice.way)}
                />
                <span>
                  <strong>{choice.title}</strong>
                  <small id={`${group}-${choice.way}-detail`}>{choice.detail}</small>
                </span>
              </label>
            ))}
          </ChoiceGroup>
        )}
        {choices.length === 1 && choices[0] && (
          <div className="acpmux-add-account-way" data-only="">
            <span>
              <strong>{choices[0].title}</strong>
              <small>{choices[0].detail}</small>
            </span>
          </div>
        )}
        <label className="acpmux-add-account-field">
          <span>{t("environment.name")}</span>
          <input
            name="name"
            aria-label={t("environment.name")}
            value={name}
            placeholder={defaultName}
            maxLength={128}
            disabled={pending}
            autoComplete="off"
            spellCheck={false}
            onChange={(event) => setName(event.target.value)}
          />
        </label>
        {way === "key" && (
          <label className="acpmux-add-account-field">
            <span>{t("picker.accountSecret")}</span>
            <input
              name="secret"
              aria-label={t("picker.accountSecret")}
              value={secret}
              placeholder="keychain:NAME"
              required
              maxLength={4096}
              disabled={pending}
              autoComplete="off"
              spellCheck={false}
              onChange={(event) => setSecret(event.target.value)}
            />
            <small>{t("picker.accountSecretHint")}</small>
          </label>
        )}
        {way === "token" && (
          <>
            <div className="acpmux-add-account-field">
              <span>{t("picker.connectClaude.step1")}</span>
              <span className="acpmux-connect-claude-command">
                <code className="selectable">{CLAUDE_SETUP_TOKEN_COMMAND}</code>
                <CopyButton
                  text={CLAUDE_SETUP_TOKEN_COMMAND}
                  label={t("picker.connectClaude.copy")}
                  className="ui-button ui-btn acpmux-connect-claude-copy"
                  size={14}
                />
              </span>
            </div>
            <label className="acpmux-add-account-field">
              <span>{t("picker.connectClaude.step2")}</span>
              <input
                name="token"
                type="password"
                aria-label={t("picker.connectClaude.step2")}
                aria-invalid={tokenCheck === "invalid" || undefined}
                aria-describedby={`${group}-token-help`}
                value={token}
                placeholder={TOKEN_PLACEHOLDER}
                required
                maxLength={4096}
                disabled={pending}
                autoComplete="off"
                spellCheck={false}
                onChange={(event) => {
                  setToken(normalizeClaudeToken(event.target.value));
                  setError(undefined);
                }}
              />
              {tokenCheck === "invalid" ? (
                <small id={`${group}-token-help`} role="alert" className="acpmux-add-account-error">
                  {t("picker.connectClaude.invalid")}
                </small>
              ) : (
                <small id={`${group}-token-help`}>{t("picker.connectClaude.tokenHint")}</small>
              )}
            </label>
          </>
        )}
        {way === "new" && <p className="acpmux-add-account-note">{t("picker.addNote.new", { brand })}</p>}
        {error && (
          <p role="alert" className="acpmux-add-account-error">
            {error}
          </p>
        )}
        <footer>
          <DialogButton
            dialogKey="escape"
            className="ui-button ui-btn"
            data-variant="subtle"
            data-size="md"
            data-disabled={pending ? "" : undefined}
            disabled={pending}
            onClick={onClose}
          >
            {t("switch.cancelPrompt")}
          </DialogButton>
          <DialogButton
            dialogKey="return"
            type="submit"
            className="ui-button ui-btn"
            data-variant="solid"
            data-size="md"
            data-disabled={pending || !ready ? "" : undefined}
            disabled={pending || !ready}
          >
            {t("picker.addAccount")}
          </DialogButton>
        </footer>
      </form>
    </Dialog>
  );
}
