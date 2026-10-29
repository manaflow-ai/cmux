"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import { useId, useState } from "react";
import { Modal } from "@/app/[locale]/components/modal";
import {
  CheckIcon,
  CopyIcon,
  InlineError,
  settingsButtonClass,
  settingsInputClass,
  settingsLabelClass,
  useAsyncAction,
} from "@/dashboard-app/components/settings-ui";
import {
  API_KEY_EXPIRY_OPTIONS,
  DEFAULT_API_KEY_EXPIRY,
  apiKeyExpiresAt,
  isApiKeyExpiryOption,
  type ApiKeyExpiryOption,
} from "../../lib/api-keys";

type CreateOptions = { description: string; expiresAt: Date };

/**
 * Create an API key: required description and an expiry (default 30 days).
 * Failures are shown in the dialog (Hexclave only logged them).
 */
export function CreateApiKeyDialog<Key>({
  open,
  onOpenChange,
  createApiKey,
  onCreated,
}: {
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
  readonly createApiKey: (options: CreateOptions) => Promise<Key>;
  readonly onCreated: (key: Key) => void;
}) {
  const t = useTranslations("dashboard.settings.apiKeys");
  const ids = { description: useId(), expiry: useId() };
  const [description, setDescription] = useState("");
  const [expiry, setExpiry] = useState<ApiKeyExpiryOption>(DEFAULT_API_KEY_EXPIRY);
  const [run, state] = useAsyncAction(t("createError"));

  const setOpen = (next: boolean) => {
    if (!next && state.pending) return;
    if (!next) {
      setDescription("");
      setExpiry(DEFAULT_API_KEY_EXPIRY);
      state.clearError();
    }
    onOpenChange(next);
  };

  const submit = async () => {
    const trimmed = description.trim();
    if (!trimmed) {
      state.setError(t("descriptionRequired"));
      return;
    }
    let key: Key | undefined;
    const ok = await run(async () => {
      key = await createApiKey({ description: trimmed, expiresAt: apiKeyExpiresAt(expiry) });
    });
    if (!ok || key === undefined) return;
    onCreated(key);
    setOpen(false);
  };

  return (
    <Modal open={open} onOpenChange={setOpen}>
      <Dialog.Title className="text-sm font-medium">{t("createTitle")}</Dialog.Title>
      <Dialog.Description className="mt-1 text-xs text-muted">{t("createDescription")}</Dialog.Description>
      <form
        noValidate
        className="mt-4 space-y-3"
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <div className="space-y-1">
          <label htmlFor={ids.description} className={settingsLabelClass}>{t("descriptionLabel")}</label>
          <input
            id={ids.description}
            value={description}
            autoFocus
            maxLength={256}
            placeholder={t("descriptionPlaceholder")}
            onChange={(event) => {
              setDescription(event.target.value);
              state.clearError();
            }}
            className={settingsInputClass}
          />
        </div>
        <div className="space-y-1">
          <label htmlFor={ids.expiry} className={settingsLabelClass}>{t("expiresIn")}</label>
          <select
            id={ids.expiry}
            value={expiry}
            onChange={(event) => {
              if (isApiKeyExpiryOption(event.target.value)) setExpiry(event.target.value);
            }}
            className={settingsInputClass}
          >
            {API_KEY_EXPIRY_OPTIONS.map((option) => (
              <option key={option} value={option}>
                {t(`expiry.${option}`)}
              </option>
            ))}
          </select>
        </div>
        <InlineError message={state.error} />
        <div className="flex justify-end gap-2 pt-2">
          <button type="button" disabled={state.pending} onClick={() => setOpen(false)} className={settingsButtonClass("secondary")}>
            {t("cancel")}
          </button>
          <button type="submit" disabled={state.pending} className={settingsButtonClass("primary")}>
            {state.pending ? t("creating") : t("createSubmit")}
          </button>
        </div>
      </form>
    </Modal>
  );
}

/**
 * Show a newly created key once. The dialog cannot be dismissed until the
 * user confirms they understand the key will not be shown again.
 */
export function ShowApiKeyDialog({
  apiKey,
  onClose,
}: {
  readonly apiKey: { readonly value: string } | null;
  readonly onClose: () => void;
}) {
  const t = useTranslations("dashboard.settings.apiKeys");
  const inputId = useId();
  const [acknowledged, setAcknowledged] = useState(false);
  const [copied, setCopied] = useState(false);
  const [copyFailed, setCopyFailed] = useState(false);

  const close = () => {
    if (!acknowledged) return;
    setAcknowledged(false);
    setCopied(false);
    setCopyFailed(false);
    onClose();
  };

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(apiKey?.value ?? "");
      setCopied(true);
      setCopyFailed(false);
    } catch {
      setCopyFailed(true);
    }
  };

  return (
    <Modal
      open={apiKey !== null}
      onOpenChange={(next) => {
        if (!next) close();
      }}
    >
      <Dialog.Title className="text-sm font-medium">{t("showTitle")}</Dialog.Title>
      <Dialog.Description className="mt-2 text-xs">
        {t("showBody")} <span className="font-medium">{t("showWarning")}</span>
      </Dialog.Description>
      <label htmlFor={inputId} className={`${settingsLabelClass} mt-4`}>{t("secretLabel")}</label>
      <div className="mt-1 flex gap-2">
        <input
          id={inputId}
          readOnly
          value={apiKey?.value ?? ""}
          onFocus={(event) => event.target.select()}
          className={`${settingsInputClass} font-mono`}
        />
        <button type="button" onClick={() => void copy()} className={settingsButtonClass("secondary", "sm")}>
          {copied ? <CheckIcon /> : <CopyIcon />}
          {copied ? t("copied") : t("copy")}
        </button>
      </div>
      <InlineError message={copyFailed ? t("copyError") : null} className="mt-1" />
      <label className="mt-4 flex items-start gap-2 text-xs">
        <input
          type="checkbox"
          checked={acknowledged}
          onChange={(event) => setAcknowledged(event.target.checked)}
          className="mt-0.5"
        />
        <span>{t("acknowledge")}</span>
      </label>
      <div className="mt-5 flex justify-end">
        <button type="button" disabled={!acknowledged} onClick={close} className={settingsButtonClass("primary")}>
          {t("close")}
        </button>
      </div>
    </Modal>
  );
}
