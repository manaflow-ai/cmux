"use client";

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useTranslations } from "next-intl";
import { dashboardClient } from "../../lib/rpc";
import { dashboardRefusal } from "../../lib/refusal";
import { cloudMachinesQuery, type CloudMachine } from "../../queries/cloud";

/** Only a paused machine can be woken; every other status hides the button. */
export function canWakeMachine(machine: Pick<CloudMachine, "status">): boolean {
  return machine.status === "paused";
}

/**
 * The sentence a failed wake shows. VM routes answer user-facing copy in
 * `message` (plan limits, a provider outage); anything else reads generic.
 */
export function wakeErrorMessage(error: unknown, fallback: string): string {
  return dashboardRefusal(error)?.message ?? fallback;
}

/**
 * Wake a paused Cloud machine from the browser, without the Mac app. The
 * request waits until the provider reports the machine running, then the
 * machine list reloads with the new status.
 */
export function MachineWakeButton({ machine }: { readonly machine: CloudMachine }) {
  const t = useTranslations("dashboard.cloud.machines");
  const queryClient = useQueryClient();
  const mutation = useMutation({
    mutationFn: () => dashboardClient.cloud.resumeMachine({ id: machine.id, teamId: machine.teamId }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: cloudMachinesQuery.queryKey }),
  });
  if (!canWakeMachine(machine)) return null;
  return (
    <div className="flex flex-col items-end gap-1">
      <button
        type="button"
        className="border border-border px-2 py-1 hover:bg-code-bg disabled:opacity-60"
        disabled={mutation.isPending}
        aria-busy={mutation.isPending}
        onClick={() => mutation.mutate()}
      >
        {mutation.isPending ? t("waking") : t("wake")}
      </button>
      {mutation.isError ? (
        <p role="alert" className="max-w-xs text-right text-xs text-foreground">
          {wakeErrorMessage(mutation.error, t("wakeError"))}
        </p>
      ) : null}
    </div>
  );
}
