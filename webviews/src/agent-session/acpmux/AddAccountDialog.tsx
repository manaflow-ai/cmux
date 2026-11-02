import { useRef, useState } from "react";
import { Dialog } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import { Select } from "../../ui/Select";
import type { NewChatAccount } from "./chatAccounts";
import { useT, type StringKey } from "./i18n";
import "./addAccount.css";

/** The picker adds a local route. Rust validates it; existing accounts and bindings stay intact. */
export function AddAccountDialog({
  add,
  kinds = ["direct-subscription", "direct-api-key"],
  onClose,
  onAdded,
}: {
  add(account: NewChatAccount): Promise<void>;
  kinds?: ("direct-subscription" | "direct-api-key")[];
  onClose(): void;
  onAdded(): void;
}) {
  const t = useT();
  const [kind, setKind] = useState<string>(kinds[0] ?? "direct-subscription");
  const [values, setValues] = useState<Record<string, string>>({});
  const [pending, setPending] = useState(false);
  const sending = useRef(false);
  const [error, setError] = useState<string>();
  const subscription = kind === "direct-subscription";
  const fields: { name: keyof NewChatAccount; label: StringKey; required?: boolean }[] = [
    { name: "id", label: "picker.accountId", required: true },
    { name: "name", label: "environment.name" },
    ...(subscription ? [{ name: "accountHome" as const, label: "picker.accountHome" as const }] : []),
    ...(kind === "direct-api-key"
      ? [{ name: "secret" as const, label: "picker.accountSecret" as const, required: true }]
      : []),
  ];
  const submit = () => {
    if (sending.current) return;
    const account: NewChatAccount = { id: values.id?.trim() ?? "", kind };
    for (const field of fields) {
      const value = values[field.name]?.trim();
      if (value) account[field.name] = value;
    }
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
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !pending) onClose();
      }}
      label={t("picker.addAccount")}
      className="acpmux-add-account"
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          submit();
        }}
      >
        <strong>{t("picker.addAccount")}</strong>
        <label>
          <span>{t("picker.accountKind")}</span>
          <Select
            value={kind}
            options={kinds.map((value) => ({
              value,
              label:
                value === "direct-subscription"
                  ? t("picker.harnessLogin")
                  : value === "direct-api-key"
                    ? t("turn.signIn.keyLabel")
                    : value,
            }))}
            label={t("picker.accountKind")}
            onChange={setKind}
            disabled={pending}
            closeOnPick
          />
        </label>
        {fields.map((field) => (
          <label key={field.name}>
            <span>{t(field.label)}</span>
            <input
              name={field.name}
              value={values[field.name] ?? ""}
              required={field.required}
              maxLength={field.name === "id" ? 128 : 4096}
              disabled={pending}
              autoComplete="off"
              spellCheck={false}
              onChange={(event) => setValues((previous) => ({ ...previous, [field.name]: event.target.value }))}
            />
          </label>
        ))}
        {kind === "direct-api-key" && <p>{t("picker.accountSecretHint")}</p>}
        {error && <p role="alert">{error}</p>}
        <footer>
          <DialogButton dialogKey="escape" disabled={pending} onClick={onClose}>
            {t("switch.cancelPrompt")}
          </DialogButton>
          <DialogButton dialogKey="return" type="submit" disabled={pending || !values.id?.trim()}>
            {t("picker.addAccount")}
          </DialogButton>
        </footer>
      </form>
    </Dialog>
  );
}
