"use client";

import { useTranslations } from "next-intl";
import { useId, useState } from "react";
import { ConfirmDialog } from "@/dashboard-app/components/settings-ui";
import { settingsInputClass } from "@/dashboard-app/components/settings-ui/styles";
import { useCancelPlan } from "@/dashboard-app/queries/billing";
import type { PickerPlanId } from "./plan-model";

export const CANCEL_REASON_CODES = ["too_expensive", "missing_feature", "not_using", "other"] as const;
export type CancelReasonCode = (typeof CANCEL_REASON_CODES)[number];

/** The procedure input: a reason only when one was picked, detail only for Other. */
export function cancelInput(input: {
  readonly teamId: string | undefined;
  readonly reason: CancelReasonCode | null;
  readonly detail: string;
}): { teamId?: string; reason?: { code: CancelReasonCode; detail?: string } } {
  const detail = input.detail.trim();
  return {
    ...(input.teamId ? { teamId: input.teamId } : {}),
    ...(input.reason
      ? { reason: { code: input.reason, ...(input.reason === "other" && detail ? { detail } : {}) } }
      : {}),
  };
}

/**
 * Cancel at the end of the period: when access ends, what stops then (the
 * plan's own feature list), and one optional question.
 */
export function CancelPlanDialog({
  open,
  onOpenChange,
  plan,
  endsOn,
  teamId,
}: {
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
  readonly plan: Exclude<PickerPlanId, "free">;
  /** Formatted period end, or null when Stripe sent none. */
  readonly endsOn: string | null;
  readonly teamId?: string;
}) {
  const t = useTranslations("dashboard.billing");
  const cancel = useCancelPlan();
  const [reason, setReason] = useState<CancelReasonCode | null>(null);
  const [detail, setDetail] = useState("");
  const groupId = useId();
  const name = t(`picker.names.${plan}`);
  const lose = t.raw(`picker.features.${plan}`) as string[];
  const setOpen = (next: boolean) => {
    if (!next) {
      setReason(null);
      setDetail("");
    }
    onOpenChange(next);
  };
  return (
    <ConfirmDialog
      open={open}
      onOpenChange={setOpen}
      title={t("cancelDialog.title", { plan: name })}
      description={
        <>
          <p>{endsOn ? t("cancelDialog.body", { plan: name, date: endsOn }) : t("cancelDialog.bodyNoDate", { plan: name })}</p>
          <ul className="mt-2 list-disc space-y-0.5 pl-4">
            {lose.map((line) => <li key={line}>{line}</li>)}
          </ul>
        </>
      }
      confirmLabel={t("cancelDialog.confirm")}
      dismissLabel={t("cancelDialog.keep", { plan: name })}
      errorMessage={t("cancelDialog.error")}
      onConfirm={async () => {
        await cancel.mutateAsync(cancelInput({ teamId, reason, detail }));
      }}
    >
      <fieldset className="mt-3">
        <legend className="text-xs text-muted">{t("cancelDialog.reasonLabel")}</legend>
        <div className="mt-1.5 grid gap-1">
          {CANCEL_REASON_CODES.map((code) => (
            <label key={code} className="flex items-center gap-2 text-xs">
              <input
                type="radio"
                name={groupId}
                value={code}
                checked={reason === code}
                onChange={() => setReason(code)}
              />
              <span>{t(`cancelDialog.reasons.${code}`)}</span>
            </label>
          ))}
        </div>
        {reason === "other" ? (
          <textarea
            aria-label={t("cancelDialog.otherPlaceholder")}
            placeholder={t("cancelDialog.otherPlaceholder")}
            maxLength={500}
            rows={2}
            value={detail}
            onChange={(event) => setDetail(event.target.value)}
            className={`${settingsInputClass} mt-2 w-full`}
          />
        ) : null}
      </fieldset>
    </ConfirmDialog>
  );
}
