import { useId, useRef, useState, type ReactNode } from "react";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import { Button } from "../../../ui/Button";
import { DialogButton } from "../../../ui/DialogButton";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import { Icon } from "../icons";
import type { ModelsAccessResult, ModelsAccessRun } from "../ops";
import type { CatalogProvider } from "../providerCatalog";
import { t } from "../strings";

export function validKey(key: string): boolean {
  return key.length <= 16_384 && /^[!-~]+$/.test(key);
}

export function useModelAccess() {
  const store = useStore();
  const pending = useRef(false);
  const [checking, setChecking] = useState(false);
  const [result, setResult] = useState<ModelsAccessResult | null>(null);
  const check = async (run: ModelsAccessRun) => {
    if (pending.current) return null;
    pending.current = true;
    setChecking(true);
    setResult(null);
    try {
      const answer = await store.checkModelsAccess(run);
      setResult(answer);
      return answer;
    } catch {
      const answer = { failure: t("settingsWindow.models.access.unavailable") };
      setResult(answer);
      return answer;
    } finally {
      pending.current = false;
      setChecking(false);
    }
  };
  return { state: checking ? "checking" : "idle", result, check, clear: () => setResult(null) };
}

export function ModelAccess({
  access,
  showModels = true,
}: {
  access: ReturnType<typeof useModelAccess>;
  showModels?: boolean;
}) {
  if (access.state === "checking") {
    return (
      <output className="row-help models-access" data-models-access="checking">
        {t("settingsPage.agents.endpoint.fetching")}
      </output>
    );
  }
  const result = access.result;
  if (!result) return null;
  if ("failure" in result) {
    return (
      <div className="row-error models-access" role="alert" data-models-access="refused">
        <Icon name="xmark" />
        <span>{result.failure}</span>
      </div>
    );
  }
  return (
    <div className="models-access" data-models-access="ok">
      <output className="row-help models-access-line">
        <Icon name="checkmark" />
        {result.models.length === 1
          ? t("settingsWindow.models.access.oneModel")
          : t("settingsWindow.models.access.modelCount", result.models.length)}
      </output>
      {showModels && (
        <ul className="models-model-list">
          {result.models.map((model) => (
            <li key={model}>{model}</li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function SecretField({
  label,
  value,
  onChange,
  disabled,
  maxLength = 16_384,
  placeholder,
  help,
}: {
  label: string;
  value: string;
  onChange(value: string): void;
  disabled: boolean;
  maxLength?: number;
  placeholder?: string;
  help?: string;
}) {
  const [revealed, setRevealed] = useState(false);
  if (!value && revealed) setRevealed(false);
  const visible = revealed && !!value;
  const reveal = t(visible ? "settingsWindow.models.secret.hide" : "settingsWindow.models.secret.show");
  const fieldId = useId();
  return (
    <div className="models-field">
      <label htmlFor={fieldId}>{label}</label>
      <span className="models-secret">
        <Input
          className="field"
          id={fieldId}
          type={visible ? "text" : "password"}
          aria-describedby={help ? `${fieldId}-help` : undefined}
          autoComplete="off"
          spellCheck={false}
          data-1p-ignore
          maxLength={maxLength}
          placeholder={placeholder}
          disabled={disabled}
          value={value}
          onChange={(event) => onChange(event.target.value)}
        />
        <Button
          type="button"
          variant="ghost"
          icon
          size="sm"
          className="models-icon-button"
          aria-label={reveal}
          title={reveal}
          disabled={disabled || !value}
          onClick={() => setRevealed(!revealed)}
        >
          <Icon name={revealed ? "eye.slash" : "eye"} />
        </Button>
      </span>
      {help && (
        <small className="row-help" id={`${fieldId}-help`}>
          {help}
        </small>
      )}
    </div>
  );
}

export function ConnectionRegion({
  provider,
  value,
  onChange,
  disabled,
}: {
  provider: CatalogProvider;
  value: string;
  onChange(value: string): void;
  disabled: boolean;
}) {
  if (!provider.regions || !provider.dialog.fields.includes("region")) return null;
  return (
    <label className="models-field">
      <span>
        {t(
          provider.accountRegion ? "settingsWindow.models.dialog.accountRegion" : "settingsWindow.models.dialog.region",
        )}
      </span>
      <select className="field" value={value} disabled={disabled} onChange={(event) => onChange(event.target.value)}>
        {!value && (
          <option value="" disabled>
            {t("settingsWindow.models.dialog.savedRegion")}
          </option>
        )}
        {provider.regions.map((region) => (
          <option key={region.id} value={region.id}>
            {t(region.label)}
          </option>
        ))}
      </select>
    </label>
  );
}

export function ConnectionError({ children }: { children: ReactNode }) {
  return (
    <div className="row-error models-access models-form-error" role="alert">
      <Icon name="warning" />
      <span>{children}</span>
    </div>
  );
}

export function ConnectionFooter({
  onClose,
  disabled = false,
  busy = false,
  label,
  failed = false,
  loading = false,
  danger = false,
  connectAction,
}: {
  onClose(): void;
  disabled?: boolean;
  busy?: boolean;
  label?: string;
  failed?: boolean;
  loading?: boolean;
  danger?: boolean;
  connectAction?: string;
}) {
  return (
    <footer className="models-footer-buttons">
      <DialogButton className="ui-button ui-btn" data-variant="subtle" dialogKey="escape" onClick={onClose}>
        {t("settingsWindow.cancel")}
      </DialogButton>
      <DialogButton
        className="ui-button ui-btn"
        data-variant="solid"
        data-danger={danger ? "" : undefined}
        dialogKey="return"
        type="submit"
        data-models-action={connectAction}
        disabled={disabled || busy || loading}
      >
        {loading && <Spinner size={14} loading />}
        {label ?? t(failed ? "settingsWindow.models.tryAgain" : "settingsWindow.models.connect")}
      </DialogButton>
    </footer>
  );
}

export function SignInWaiting({
  children,
  title = t("settingsWindow.models.waiting.title"),
}: {
  children?: ReactNode;
  title?: string;
}) {
  return (
    <div className="models-waiting" data-models-waiting="">
      <output>{title}</output>
      {children && <span className="row-help">{children}</span>}
    </div>
  );
}
