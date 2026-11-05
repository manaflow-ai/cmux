import { useId, useRef, useState } from "react";
import { ChoiceGroup } from "../../ui/ChoiceGroup";
import { Dialog } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import type { NewChatAccount } from "./chatAccounts";
import { useT, type StringKey } from "./i18n";
import "./addAccount.css";

type Kind = "direct-subscription" | "direct-api-key";
/** new: a fresh login folder of its own; cli: the CLI's own login on this Mac; key: an API key. */
type Way = "new" | "cli" | "key";

/** The families whose CLI keeps its login in a folder a second account can have its own copy of. */
const BRANDS: Record<string, { brand: StringKey; cli: StringKey; folder: string }> = {
  claude: { brand: "picker.addBrand.claude", cli: "picker.addCli.claude", folder: "~/.claude" },
  codex: { brand: "picker.addBrand.codex", cli: "picker.addCli.codex", folder: "~/.codex" },
};

/** A route id from a name: lowercase letters, digits and `-` (routes.rs), unique among `taken`. */
export function accountIdFor(name: string, fallback: string, taken: readonly string[]): string {
  const slug = (text: string) =>
    text
      .normalize("NFKD")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 48);
  const base = slug(name) || slug(fallback) || "account";
  if (!taken.includes(base)) return base;
  for (let n = 2; ; n++) if (!taken.includes(`${base}-${n}`)) return `${base}-${n}`;
}

/** The picker adds a local route. Rust validates it; existing accounts and bindings stay intact.
 * Nobody types an id or a folder: the id comes from the name, and a new login gets its own folder
 * under ~/.cmux/accounts (the native host expands `~/`). */
export function AddAccountDialog({
  add,
  family,
  kinds = ["direct-subscription", "direct-api-key"],
  existing = [],
  onClose,
  onAdded,
}: {
  add(account: NewChatAccount): Promise<void>;
  family: string;
  kinds?: Kind[];
  /** The ids of the routes there are, so a new one never asks to replace one. */
  existing?: readonly string[];
  onClose(): void;
  onAdded(): void;
}) {
  const t = useT();
  const group = useId();
  const known = BRANDS[family];
  const ways: Way[] = [
    ...(kinds.includes("direct-subscription") ? (known ? (["new", "cli"] as const) : (["cli"] as const)) : []),
    ...(kinds.includes("direct-api-key") ? (["key"] as const) : []),
  ];
  const [way, setWay] = useState<Way>(ways[0] ?? "key");
  const [name, setName] = useState("");
  const [secret, setSecret] = useState("");
  const [pending, setPending] = useState(false);
  const sending = useRef(false);
  const [error, setError] = useState<string>();
  const brand = known ? t(known.brand) : family;
  const cli = known ? t(known.cli) : t("picker.harnessLogin");
  // A second login is "ChatGPT 2", then 3, ...: the first number no route has taken.
  const nextName = () => {
    for (let n = 2; ; n++) {
      const candidate = t("picker.addName.new", { brand, n });
      if (accountIdFor(candidate, family, existing) === accountIdFor(candidate, family, [])) return candidate;
    }
  };
  const defaultName =
    way === "new" ? nextName() : way === "cli" ? t("picker.addName.cli", { cli }) : t("picker.addName.key", { brand });
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
        : { way: value, title: t("picker.addWay.key"), detail: t("picker.addWay.keyDetail") },
  );
  const ready = way !== "key" || !!secret.trim();
  const submit = () => {
    if (sending.current || !ready) return;
    const account: NewChatAccount = {
      id,
      kind: way === "key" ? "direct-api-key" : "direct-subscription",
      family,
      name: name.trim() || defaultName,
    };
    if (way === "new") account.accountHome = folder;
    if (way === "key") account.secret = secret.trim();
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
      className="acpmux-add-account"
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
              <label key={choice.way} className="acpmux-add-account-way" htmlFor={`${group}-${choice.way}`}>
                <input
                  id={`${group}-${choice.way}`}
                  type="radio"
                  name={group}
                  value={choice.way}
                  checked={choice.way === way}
                  disabled={pending}
                  onChange={() => setWay(choice.way)}
                />
                <span>
                  <strong>{choice.title}</strong>
                  <small>{choice.detail}</small>
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
        {way === "new" && <p className="acpmux-add-account-note">{t("picker.addNote.new", { brand })}</p>}
        {error && (
          <p role="alert" className="acpmux-add-account-error">
            {error}
          </p>
        )}
        <footer>
          <DialogButton
            dialogKey="escape"
            className="ui-btn"
            data-variant="subtle"
            data-size="md"
            disabled={pending}
            onClick={onClose}
          >
            {t("switch.cancelPrompt")}
          </DialogButton>
          <DialogButton
            dialogKey="return"
            type="submit"
            className="ui-btn"
            data-variant="solid"
            data-size="md"
            disabled={pending || !ready}
          >
            {t("picker.addAccount")}
          </DialogButton>
        </footer>
      </form>
    </Dialog>
  );
}
