"use client";

import { useTranslations } from "next-intl";
import { useRouter } from "../../../../i18n/navigation";
import { useState } from "react";
import type { FormEvent, ReactNode } from "react";

type FormKind = "claude" | "anthropic" | "codex" | "openai";
type FormStatus = {
  readonly state: "idle" | "submitting" | "success" | "error";
  readonly message?: string;
};

const idleStatus: FormStatus = { state: "idle" };

export function AddAiAccountForms({ teamId }: { teamId: string }) {
  const t = useTranslations("dashboard.aiAccounts");
  const router = useRouter();
  const [statuses, setStatuses] = useState<Record<FormKind, FormStatus>>({
    claude: idleStatus,
    anthropic: idleStatus,
    codex: idleStatus,
    openai: idleStatus,
  });

  const setStatus = (kind: FormKind, status: FormStatus) => {
    setStatuses((current) => ({ ...current, [kind]: status }));
  };

  const submitAccount = async (
    kind: FormKind,
    form: HTMLFormElement,
    payload: Record<string, unknown>,
  ) => {
    setStatus(kind, { state: "submitting" });
    try {
      const response = await fetch(`/api/subrouter/accounts?teamId=${encodeURIComponent(teamId)}&validate=1`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      });
      if (!response.ok) {
        setStatus(kind, { state: "error", message: errorMessageForStatus(response.status, t) });
        return;
      }
      form.reset();
      setStatus(kind, { state: "success", message: t("addSuccess") });
      router.refresh();
    } catch {
      setStatus(kind, { state: "error", message: t("addError") });
    }
  };

  const submitClaude = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    const parsed = parseJsonObject(String(data.get("oauthJson") ?? ""));
    if (!parsed) {
      setStatus("claude", { state: "error", message: t("jsonError") });
      return;
    }
    const claudeAiOauth = isRecord(parsed.claudeAiOauth) ? parsed.claudeAiOauth : parsed;
    await submitAccount("claude", form, {
      provider: "claude",
      label: labelValue(data),
      claudeAiOauth,
    });
  };

  const submitAnthropic = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    await submitAccount("anthropic", form, {
      provider: "anthropic-apikey",
      label: labelValue(data),
      apiKey: String(data.get("apiKey") ?? ""),
    });
  };

  const submitCodex = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    const parsed = parseJsonObject(String(data.get("oauthJson") ?? ""));
    if (!parsed) {
      setStatus("codex", { state: "error", message: t("jsonError") });
      return;
    }
    const tokens = isRecord(parsed.tokens) ? parsed.tokens : parsed;
    await submitAccount("codex", form, {
      provider: "codex",
      label: labelValue(data),
      tokens,
    });
  };

  const submitOpenAi = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    await submitAccount("openai", form, {
      provider: "openai-apikey",
      label: labelValue(data),
      apiKey: String(data.get("apiKey") ?? ""),
    });
  };

  return (
    <div className="space-y-4">
      <ProviderForm
        title={t("providerClaude")}
        labelText={t("labelField")}
        labelPlaceholder={t("labelPlaceholder")}
        submitLabel={t("addClaude")}
        status={statuses.claude}
        onSubmit={submitClaude}
      >
        <JsonField
          label={t("oauthJsonField")}
          placeholder={t("claudeJsonPlaceholder")}
        />
      </ProviderForm>

      <ProviderForm
        title={t("providerAnthropicApiKey")}
        labelText={t("labelField")}
        labelPlaceholder={t("labelPlaceholder")}
        submitLabel={t("addAnthropic")}
        status={statuses.anthropic}
        onSubmit={submitAnthropic}
      >
        <SecretField
          name="apiKey"
          label={t("apiKeyField")}
          placeholder={t("anthropicKeyPlaceholder")}
        />
      </ProviderForm>

      <ProviderForm
        title={t("providerCodex")}
        labelText={t("labelField")}
        labelPlaceholder={t("labelPlaceholder")}
        submitLabel={t("addCodex")}
        status={statuses.codex}
        onSubmit={submitCodex}
      >
        <JsonField
          label={t("oauthJsonField")}
          placeholder={t("codexJsonPlaceholder")}
        />
      </ProviderForm>

      <ProviderForm
        title={t("providerOpenAiApiKey")}
        labelText={t("labelField")}
        labelPlaceholder={t("labelPlaceholder")}
        submitLabel={t("addOpenAi")}
        status={statuses.openai}
        onSubmit={submitOpenAi}
      >
        <SecretField
          name="apiKey"
          label={t("apiKeyField")}
          placeholder={t("openAiKeyPlaceholder")}
        />
      </ProviderForm>
    </div>
  );
}

export function DeleteAiAccountButton({
  teamId,
  accountId,
}: {
  teamId: string;
  accountId: string;
}) {
  const t = useTranslations("dashboard.aiAccounts");
  const router = useRouter();
  const [status, setStatus] = useState<FormStatus>(idleStatus);

  const deleteAccount = async () => {
    if (status.state === "submitting") return;
    setStatus({ state: "submitting" });
    try {
      const response = await fetch(
        `/api/subrouter/accounts/${encodeURIComponent(accountId)}?teamId=${encodeURIComponent(teamId)}`,
        { method: "DELETE" },
      );
      if (!response.ok) {
        setStatus({ state: "error", message: errorMessageForStatus(response.status, t) });
        return;
      }
      setStatus(idleStatus);
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("deleteError") });
    }
  };

  return (
    <div className="text-right">
      <button
        type="button"
        onClick={deleteAccount}
        disabled={status.state === "submitting"}
        className="rounded-md border border-border px-3 py-1.5 text-sm font-medium transition-colors hover:border-foreground disabled:cursor-not-allowed disabled:opacity-60"
      >
        {status.state === "submitting" ? t("deletingAction") : t("deleteAction")}
      </button>
      {status.state === "error" && status.message ? (
        <div className="mt-1 text-xs text-red-500">{status.message}</div>
      ) : null}
    </div>
  );
}

function ProviderForm({
  title,
  labelText,
  labelPlaceholder,
  submitLabel,
  status,
  onSubmit,
  children,
}: {
  title: string;
  labelText: string;
  labelPlaceholder: string;
  submitLabel: string;
  status: FormStatus;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
  children: ReactNode;
}) {
  return (
    <form onSubmit={onSubmit} className="rounded-lg border border-border p-4">
      <h3 className="text-sm font-semibold tracking-tight">{title}</h3>
      <label className="mt-3 block text-xs font-medium text-muted">
        {labelText}
        <input
          name="label"
          className="mt-1 w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground outline-none transition-colors focus:border-foreground"
          placeholder={labelPlaceholder}
        />
      </label>
      {children}
      <button
        type="submit"
        disabled={status.state === "submitting"}
        className="mt-3 w-full rounded-md bg-foreground px-3 py-2 text-sm font-medium text-background transition-opacity disabled:cursor-not-allowed disabled:opacity-60"
      >
        {submitLabel}
      </button>
      {status.state === "success" && status.message ? (
        <div className="mt-2 text-xs text-green-600">{status.message}</div>
      ) : null}
      {status.state === "error" && status.message ? (
        <div className="mt-2 text-xs text-red-500">{status.message}</div>
      ) : null}
    </form>
  );
}

function JsonField({ label, placeholder }: { label: string; placeholder: string }) {
  return (
    <label className="mt-3 block text-xs font-medium text-muted">
      {label}
      <textarea
        name="oauthJson"
        required
        rows={5}
        className="mt-1 w-full resize-y rounded-md border border-border bg-background px-3 py-2 font-mono text-xs text-foreground outline-none transition-colors focus:border-foreground"
        placeholder={placeholder}
      />
    </label>
  );
}

function SecretField({
  name,
  label,
  placeholder,
}: {
  name: string;
  label: string;
  placeholder: string;
}) {
  return (
    <label className="mt-3 block text-xs font-medium text-muted">
      {label}
      <input
        name={name}
        type="password"
        required
        className="mt-1 w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground outline-none transition-colors focus:border-foreground"
        placeholder={placeholder}
      />
    </label>
  );
}

function labelValue(data: FormData): string | undefined {
  const value = String(data.get("label") ?? "").trim();
  return value ? value : undefined;
}

function parseJsonObject(value: string): Record<string, unknown> | null {
  try {
    const parsed = JSON.parse(value);
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function errorMessageForStatus(
  status: number,
  t: ReturnType<typeof useTranslations<"dashboard.aiAccounts">>,
): string {
  if (status === 400) return t("validationError");
  if (status === 403) return t("teamAccessError");
  if (status === 503) return t("notConfiguredTitle");
  return t("addError");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
