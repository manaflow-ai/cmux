"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import { useId, useState, type ReactNode } from "react";
import { Modal } from "@/app/[locale]/components/modal";
import { InlineError } from "./feedback";
import { settingsButtonClass, settingsInputClass } from "./styles";
import { useAsyncAction } from "./use-async-action";

/**
 * A confirmation dialog for a destructive or consequential action.
 *
 * - `acknowledgement` adds a checkbox the user must tick first.
 * - `typedConfirmation` requires typing that exact text first.
 *
 * `onConfirm` may throw; the dialog stays open and shows `errorMessage` (or
 * a generic translated error). On success the dialog closes. Transient input
 * resets whenever the dialog closes, so reopening starts clean.
 */
export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel,
  onConfirm,
  tone = "danger",
  acknowledgement,
  typedConfirmation,
  errorMessage,
  describeError,
  children,
}: {
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
  readonly title: string;
  readonly description?: ReactNode;
  readonly confirmLabel: string;
  readonly onConfirm: () => Promise<void>;
  readonly tone?: "danger" | "default";
  readonly acknowledgement?: string;
  readonly typedConfirmation?: string;
  readonly errorMessage?: string;
  readonly describeError?: (error: unknown) => string | null;
  readonly children?: ReactNode;
}) {
  const t = useTranslations("dashboard.settings.ui");
  const inputId = useId();
  const [acknowledged, setAcknowledged] = useState(false);
  const [typed, setTyped] = useState("");
  const [run, state] = useAsyncAction(errorMessage ?? t("actionError"), describeError);

  const setOpen = (next: boolean) => {
    if (!next && state.pending) return;
    if (!next) {
      setAcknowledged(false);
      setTyped("");
      state.clearError();
    }
    onOpenChange(next);
  };

  const blocked =
    (acknowledgement !== undefined && !acknowledged) ||
    (typedConfirmation !== undefined && typed.trim() !== typedConfirmation);

  const confirm = async () => {
    if (blocked) return;
    if (await run(onConfirm)) setOpen(false);
  };

  return (
    <Modal open={open} onOpenChange={setOpen}>
      <Dialog.Title className="text-sm font-medium">{title}</Dialog.Title>
      {description ? (
        <Dialog.Description render={<div />} className="mt-2 text-xs text-muted">
          {description}
        </Dialog.Description>
      ) : null}
      {children ? <div className="mt-3">{children}</div> : null}
      {typedConfirmation !== undefined ? (
        <div className="mt-4 space-y-1">
          <label htmlFor={inputId} className="block text-xs text-muted">
            {t("typeToConfirm", { text: typedConfirmation })}
          </label>
          <input
            id={inputId}
            value={typed}
            autoComplete="off"
            onChange={(event) => setTyped(event.target.value)}
            className={settingsInputClass}
          />
        </div>
      ) : null}
      {acknowledgement !== undefined ? (
        <label className="mt-4 flex items-start gap-2 text-xs">
          <input
            type="checkbox"
            checked={acknowledged}
            onChange={(event) => setAcknowledged(event.target.checked)}
            className="mt-0.5"
          />
          <span>{acknowledgement}</span>
        </label>
      ) : null}
      <InlineError message={state.error} className="mt-3" />
      <div className="mt-5 flex justify-end gap-2">
        <button
          type="button"
          disabled={state.pending}
          onClick={() => setOpen(false)}
          className={settingsButtonClass("secondary")}
        >
          {t("cancel")}
        </button>
        <button
          type="button"
          disabled={blocked || state.pending}
          onClick={() => void confirm()}
          className={settingsButtonClass(tone === "danger" ? "danger" : "primary")}
        >
          {state.pending ? t("working") : confirmLabel}
        </button>
      </div>
    </Modal>
  );
}
