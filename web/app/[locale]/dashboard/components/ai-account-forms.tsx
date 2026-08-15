"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import { useRouter } from "../../../../i18n/navigation";
import { useState, type ReactNode } from "react";
import { Modal } from "../../components/modal";
import { CopyButton } from "../vault/copy-button";

type FormStatus = {
  readonly state: "idle" | "submitting" | "success" | "error";
  readonly message?: string;
};

const idleStatus: FormStatus = { state: "idle" };

export function AddAiAccountForms() {
  const t = useTranslations("dashboard.aiAccounts");
  return (
    <div className="border border-border p-3">
      <p className="text-sm text-muted">{t("cliAddBody")}</p>
      <div className="mt-4 space-y-2">
        <ToolCommandRow
          name={t("codexTool")}
          command="npx coderouter@latest add codex"
          label={t("codexCommand")}
          copied={t("copied")}
          logo={<CodexLogo />}
        />
        <ToolCommandRow
          name={t("opencodeTool")}
          command="npx coderouter@latest add opencode"
          label={t("opencodeCommand")}
          copied={t("copied")}
          logo={<OpenCodeLogo />}
        />
      </div>
    </div>
  );
}

function ToolCommandRow({
  name,
  command,
  label,
  copied,
  logo,
}: {
  name: string;
  command: string;
  label: string;
  copied: string;
  logo: ReactNode;
}) {
  return (
    <div className="flex items-center justify-between gap-3 border border-border px-3 py-2">
      <div className="flex min-w-0 items-center gap-2.5">
        <span className="shrink-0 text-foreground">{logo}</span>
        <div className="min-w-0">
          <div className="text-xs font-medium text-foreground">{name}</div>
          <code className="mt-0.5 block break-all font-mono text-xs text-foreground">
            {command}
          </code>
        </div>
      </div>
      <CopyButton value={command} label={label} copiedLabel={copied} />
    </div>
  );
}

function CodexLogo() {
  return (
    <svg
      aria-hidden="true"
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="currentColor"
    >
      <path d="M12 2.5 13.7 9.3 20.5 11l-6.8 1.7L12 19.5l-1.7-6.8L3.5 11l6.8-1.7L12 2.5z" />
    </svg>
  );
}

function OpenCodeLogo() {
  return (
    <svg
      aria-hidden="true"
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.25"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="m6 8-4 4 4 4" />
      <path d="m18 8 4 4-4 4" />
      <path d="m13 5-2 14" />
    </svg>
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
  const [confirmOpen, setConfirmOpen] = useState(false);

  const deleteAccount = async () => {
    if (status.state === "submitting") return;
    setConfirmOpen(false);
    setStatus({ state: "submitting" });
    try {
      const response = await fetch(
        `/api/subrouter/accounts/${encodeURIComponent(accountId)}?teamId=${encodeURIComponent(teamId)}`,
        { method: "DELETE" },
      );
      if (!response.ok) {
        setStatus({
          state: "error",
          message: errorMessageForStatus(response.status, t, t("deleteError")),
        });
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
        onClick={() => setConfirmOpen(true)}
        disabled={status.state === "submitting"}
        className="border border-border px-3 py-1.5 text-sm transition-colors hover:bg-foreground hover:text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-60"
      >
        {status.state === "submitting" ? t("deletingAction") : t("deleteAction")}
      </button>
      {status.state === "error" && status.message ? (
        <div className="mt-1 text-xs text-foreground">{status.message}</div>
      ) : null}
      <Modal open={confirmOpen} onOpenChange={setConfirmOpen}>
        <Dialog.Title className="text-left text-sm font-medium">
          {t("deleteConfirmTitle")}
        </Dialog.Title>
        <Dialog.Description className="mt-2 text-left text-xs text-muted">
          {t("deleteConfirmBody")}
        </Dialog.Description>
        <div className="mt-5 flex justify-end gap-2">
          <Dialog.Close className="border border-border px-3 py-1.5 text-sm transition-colors hover:bg-foreground hover:text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground">
            {t("cancelAction")}
          </Dialog.Close>
          <button
            type="button"
            onClick={deleteAccount}
            className="border border-foreground bg-foreground px-3 py-1.5 text-sm text-background transition-colors hover:bg-background hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          >
            {t("deleteAction")}
          </button>
        </div>
      </Modal>
    </div>
  );
}

function errorMessageForStatus(
  status: number,
  t: ReturnType<typeof useTranslations<"dashboard.aiAccounts">>,
  fallback: string,
): string {
  if (status === 400) return t("validationError");
  if (status === 403) return t("teamAccessError");
  if (status === 503) return t("notConfiguredTitle");
  return fallback;
}
