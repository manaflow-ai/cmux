"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import { useState, type FormEvent } from "react";
import { useRouter } from "../../../../i18n/navigation";
import { Modal } from "../../components/modal";
import type {
  ClaudeUpstreamDescription,
  ClaudeUpstreamKind,
} from "../../../../services/coderouter/claudeUpstream";

type FormStatus = {
  readonly state: "idle" | "submitting" | "success" | "error";
  readonly message?: string;
};

const idleStatus: FormStatus = { state: "idle" };
const KINDS: readonly ClaudeUpstreamKind[] = ["anthropic_api_key", "anthropic_oauth", "bedrock"];

const inputClass =
  "w-full border border-border bg-background px-2 py-1.5 font-mono text-xs text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground";
const buttonClass =
  "border border-border px-3 py-1.5 text-sm transition-colors hover:bg-foreground hover:text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-60";
const primaryButtonClass =
  "border border-foreground bg-foreground px-3 py-1.5 text-sm text-background transition-colors hover:bg-background hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-60";

export function ClaudeUpstreamSection({
  teamId,
  current,
  canManage,
  loadFailed,
}: {
  readonly teamId: string;
  readonly current: ClaudeUpstreamDescription | null;
  readonly canManage: boolean;
  readonly loadFailed: boolean;
}) {
  const t = useTranslations("dashboard.claudeUpstream");
  return (
    <section className="mb-4">
      <div className="mb-2">
        <h2 className="text-sm font-medium">{t("title")}</h2>
        <p className="mt-1 max-w-2xl text-xs text-muted">{t("description")}</p>
      </div>
      {loadFailed ? (
        <div className="border border-border p-3">
          <div className="text-sm font-medium">{t("loadErrorTitle")}</div>
          <p className="mt-1 text-xs text-muted">{t("loadErrorBody")}</p>
        </div>
      ) : (
        <div className="space-y-3">
          <CurrentUpstreamRow teamId={teamId} current={current} canManage={canManage} />
          {canManage ? <ClaudeUpstreamForms teamId={teamId} /> : null}
        </div>
      )}
    </section>
  );
}

function CurrentUpstreamRow({
  teamId,
  current,
  canManage,
}: {
  readonly teamId: string;
  readonly current: ClaudeUpstreamDescription | null;
  readonly canManage: boolean;
}) {
  const t = useTranslations("dashboard.claudeUpstream");
  if (!current) {
    return (
      <div className="border border-border p-3">
        <div className="text-sm font-medium">{t("emptyTitle")}</div>
        <p className="mt-1 text-xs text-muted">{t("emptyBody")}</p>
      </div>
    );
  }
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 border border-border px-3 py-2 text-sm">
      <div className="min-w-0">
        <div className="text-xs text-muted">{t("currentLabel")}</div>
        <div className="mt-0.5">{kindLabel(current.kind, t)}</div>
        <div className="mt-0.5 font-mono text-xs text-muted">
          {current.identifier}
          {current.region ? ` · ${current.region}` : ""}
        </div>
      </div>
      {canManage ? <RemoveUpstreamButton teamId={teamId} /> : null}
    </div>
  );
}

function ClaudeUpstreamForms({ teamId }: { readonly teamId: string }) {
  const t = useTranslations("dashboard.claudeUpstream");
  const router = useRouter();
  const [kind, setKind] = useState<ClaudeUpstreamKind>("anthropic_api_key");
  const [status, setStatus] = useState<FormStatus>(idleStatus);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (status.state === "submitting") return;
    const form = event.currentTarget;
    const data = new FormData(form);
    const body = bodyForKind(kind, data);
    setStatus({ state: "submitting" });
    try {
      const response = await fetch(
        `/api/coderouter/claude-upstream?teamId=${encodeURIComponent(teamId)}`,
        {
          method: "PUT",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        },
      );
      if (!response.ok) {
        setStatus({
          state: "error",
          message: errorMessageForStatus(response.status, t, t("saveError")),
        });
        return;
      }
      form.reset();
      setStatus({ state: "success", message: t("saveSuccess") });
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("saveError") });
    }
  };

  return (
    <div className="border border-border p-3">
      <div className="mb-3 flex flex-wrap gap-2" role="tablist" aria-label={t("kindSelectorLabel")}>
        {KINDS.map((candidate) => (
          <button
            key={candidate}
            type="button"
            role="tab"
            aria-selected={candidate === kind}
            onClick={() => {
              setKind(candidate);
              setStatus(idleStatus);
            }}
            className={`border px-3 py-1.5 text-sm transition-colors focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground ${
              candidate === kind
                ? "border-foreground bg-foreground text-background"
                : "border-border text-muted hover:text-foreground"
            }`}
          >
            {kindLabel(candidate, t)}
          </button>
        ))}
      </div>
      <form onSubmit={submit} className="space-y-3">
        {kind === "anthropic_api_key" ? (
          <Field label={t("apiKeyField")} name="apiKey" placeholder="sk-ant-api03-..." />
        ) : kind === "anthropic_oauth" ? (
          <div className="space-y-2">
            <Field label={t("oauthTokenField")} name="token" placeholder="sk-ant-oat01-..." />
            <p className="text-xs text-muted">
              {t("oauthHint")}{" "}
              <code className="font-mono text-foreground">claude setup-token</code>
            </p>
          </div>
        ) : (
          <div className="grid gap-3 md:grid-cols-2">
            <Field label={t("regionField")} name="region" placeholder="us-east-1" mono={false} />
            <Field label={t("accessKeyIdField")} name="accessKeyId" placeholder="AKIA..." />
            <Field label={t("secretAccessKeyField")} name="secretAccessKey" placeholder="" />
            <Field
              label={t("sessionTokenField")}
              name="sessionToken"
              placeholder={t("optionalPlaceholder")}
              required={false}
            />
          </div>
        )}
        <div className="flex flex-wrap items-center gap-3">
          <button type="submit" disabled={status.state === "submitting"} className={primaryButtonClass}>
            {status.state === "submitting" ? t("savingAction") : t("saveAction")}
          </button>
          {status.message ? (
            <span className="text-xs text-foreground">{status.message}</span>
          ) : null}
        </div>
      </form>
    </div>
  );
}

function Field({
  label,
  name,
  placeholder,
  required = true,
  mono = true,
}: {
  readonly label: string;
  readonly name: string;
  readonly placeholder: string;
  readonly required?: boolean;
  readonly mono?: boolean;
}) {
  const id = `claude-upstream-${name}`;
  return (
    <label htmlFor={id} className="block">
      <span className="mb-1 block text-xs text-muted">{label}</span>
      <input
        id={id}
        name={name}
        type="password"
        autoComplete="off"
        spellCheck={false}
        required={required}
        placeholder={placeholder}
        className={mono ? inputClass : inputClass.replace("font-mono ", "")}
      />
    </label>
  );
}

function RemoveUpstreamButton({ teamId }: { readonly teamId: string }) {
  const t = useTranslations("dashboard.claudeUpstream");
  const router = useRouter();
  const [status, setStatus] = useState<FormStatus>(idleStatus);
  const [confirmOpen, setConfirmOpen] = useState(false);

  const remove = async () => {
    if (status.state === "submitting") return;
    setConfirmOpen(false);
    setStatus({ state: "submitting" });
    try {
      const response = await fetch(
        `/api/coderouter/claude-upstream?teamId=${encodeURIComponent(teamId)}`,
        { method: "DELETE" },
      );
      if (!response.ok && response.status !== 404) {
        setStatus({
          state: "error",
          message: errorMessageForStatus(response.status, t, t("removeError")),
        });
        return;
      }
      setStatus(idleStatus);
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("removeError") });
    }
  };

  return (
    <div className="text-right">
      <button
        type="button"
        onClick={() => setConfirmOpen(true)}
        disabled={status.state === "submitting"}
        className={buttonClass}
      >
        {status.state === "submitting" ? t("removingAction") : t("removeAction")}
      </button>
      {status.state === "error" && status.message ? (
        <div className="mt-1 text-xs text-foreground">{status.message}</div>
      ) : null}
      <Modal open={confirmOpen} onOpenChange={setConfirmOpen}>
        <Dialog.Title className="text-left text-sm font-medium">
          {t("removeConfirmTitle")}
        </Dialog.Title>
        <Dialog.Description className="mt-2 text-left text-xs text-muted">
          {t("removeConfirmBody")}
        </Dialog.Description>
        <div className="mt-5 flex justify-end gap-2">
          <Dialog.Close className={buttonClass}>{t("cancelAction")}</Dialog.Close>
          <button type="button" onClick={remove} className={primaryButtonClass}>
            {t("removeAction")}
          </button>
        </div>
      </Modal>
    </div>
  );
}

function bodyForKind(kind: ClaudeUpstreamKind, data: FormData): Record<string, string> {
  const field = (name: string) => String(data.get(name) ?? "").trim();
  switch (kind) {
    case "anthropic_api_key":
      return { kind, apiKey: field("apiKey") };
    case "anthropic_oauth":
      return { kind, token: field("token") };
    case "bedrock": {
      const sessionToken = field("sessionToken");
      return {
        kind,
        region: field("region"),
        accessKeyId: field("accessKeyId"),
        secretAccessKey: field("secretAccessKey"),
        ...(sessionToken ? { sessionToken } : {}),
      };
    }
  }
}

type Translator = ReturnType<typeof useTranslations<"dashboard.claudeUpstream">>;

function kindLabel(kind: ClaudeUpstreamKind, t: Translator): string {
  switch (kind) {
    case "anthropic_api_key":
      return t("kindApiKey");
    case "anthropic_oauth":
      return t("kindOauth");
    case "bedrock":
      return t("kindBedrock");
  }
}

function errorMessageForStatus(status: number, t: Translator, fallback: string): string {
  if (status === 400) return t("validationError");
  if (status === 403) return t("teamAccessError");
  return fallback;
}
