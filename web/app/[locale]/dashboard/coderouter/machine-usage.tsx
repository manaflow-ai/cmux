import type { getTranslations } from "next-intl/server";

import { reportCoderouterFailure } from "@/services/coderouter/observability";
import { listTeamMachines } from "@/services/coderouter/teamMachines";
import { loadCoderouterTeamMachineMetrics } from "@/services/coderouter/vmMetrics";
import {
  teamMachineUsage,
  type TeamMachineUsage,
} from "@/services/coderouter/vmUsageContract";

type Translator = Awaited<ReturnType<typeof getTranslations>>;

export type MachineUsage =
  | { readonly kind: "unavailable"; readonly periodDays: number }
  | {
      readonly kind: "ready";
      readonly periodDays: number;
      readonly machines: readonly TeamMachineUsage[];
    };

const PERIOD_DAYS = 30;

/** Server-side load for the Machines card. Fails closed to "unavailable". */
export async function loadMachineUsage(teamId: string): Promise<MachineUsage> {
  let owned;
  try {
    owned = await listTeamMachines(teamId);
  } catch (error) {
    reportCoderouterFailure("rds", error, { operation: "list_team_machines" });
    return { kind: "unavailable", periodDays: PERIOD_DAYS };
  }
  const metrics = await loadCoderouterTeamMachineMetrics(teamId, "dashboard");
  if (metrics.kind === "unavailable") {
    return { kind: "unavailable", periodDays: PERIOD_DAYS };
  }
  return {
    kind: "ready",
    periodDays: metrics.periodDays,
    machines: teamMachineUsage(metrics, owned),
  };
}

export function MachineUsageSection({
  locale,
  t,
  teamName,
  usage,
}: {
  readonly locale: string;
  readonly t: Translator;
  readonly teamName: string;
  readonly usage: MachineUsage;
}) {
  const days = usage.periodDays;
  return (
    <section className="mb-4 border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-sm font-medium">{t("machines.title")}</h2>
          <p className="mt-1 text-xs text-muted">
            {t("machines.description", { team: teamName, days })}
          </p>
        </div>
      </div>
      {usage.kind === "unavailable" ? (
        <p className="mt-2 text-xs text-muted">{t("machines.unavailable")}</p>
      ) : usage.machines.length === 0 ? (
        <p className="mt-2 text-xs text-muted">{t("machines.empty", { days })}</p>
      ) : (
        <MachineTable locale={locale} t={t} machines={usage.machines} />
      )}
      <p className="mt-2 text-[11px] leading-5 text-muted">
        {t("machines.estimateNote")}
      </p>
    </section>
  );
}

function MachineTable({
  locale,
  t,
  machines,
}: {
  readonly locale: string;
  readonly t: Translator;
  readonly machines: readonly TeamMachineUsage[];
}) {
  const number = new Intl.NumberFormat(locale, {
    notation: "compact",
    maximumFractionDigits: 1,
  });
  const currency = new Intl.NumberFormat(locale, {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  });
  return (
    <div className="mt-3 border border-border">
      <div className="hidden grid-cols-[2fr_1fr_1fr] gap-3 border-b border-border px-3 py-2 text-xs text-muted md:grid">
        <div>{t("machines.machineColumn")}</div>
        <div className="text-right">{t("machines.tokensColumn")}</div>
        <div className="text-right">{t("machines.apiEquivalentColumn")}</div>
      </div>
      {machines.map((machine) => (
        <div
          key={machine.vmId}
          className="grid gap-2 border-b border-border px-3 py-2 text-sm last:border-b-0 md:grid-cols-[2fr_1fr_1fr] md:items-center md:gap-3"
        >
          <div className="min-w-0">
            <div className="truncate">
              {machine.displayName ?? t("machines.unnamed")}
            </div>
            <div className="truncate font-mono text-[11px] text-muted">
              {machine.vmId}
            </div>
          </div>
          <div className="font-mono text-xs tabular-nums md:text-right">
            <span className="mr-2 font-sans text-xs text-muted md:hidden">
              {t("machines.tokensColumn")}
            </span>
            {number.format(machine.totals.totalTokens)}
          </div>
          <div className="font-mono text-xs tabular-nums md:text-right">
            <span className="mr-2 font-sans text-xs text-muted md:hidden">
              {t("machines.apiEquivalentColumn")}
            </span>
            {currency.format(machine.totals.apiEquivalentUsd)}
          </div>
        </div>
      ))}
    </div>
  );
}
