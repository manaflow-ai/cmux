"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { useSearch } from "@tanstack/react-router";
import { useLocale, useTranslations } from "next-intl";
import type { CoderouterTeamMetrics } from "@/services/coderouter/teamMetrics";
import type { TeamMachineUsage } from "@/services/coderouter/vmUsageContract";
import type { MachineUsage } from "../../lib/coderouter-types";
import { coderouterOverviewQuery } from "../../queries/coderouter";
import { CoderouterAccountsSection } from "./coderouter-accounts";
import { CoderouterPageFrame } from "./coderouter-frame";

export function CoderouterScreen() {
  // `team` is the shell-wide scope every dashboard route inherits.
  const { team } = useSearch({ strict: false });
  const { data } = useSuspenseQuery(coderouterOverviewQuery(team));
  const { selectedTeam } = data;
  return (
    <CoderouterPageFrame>
      <TeamMetricsSection metrics={data.metrics} teamName={selectedTeam.name} />

      <CoderouterAccountsSection
        key={selectedTeam.id}
        teamId={selectedTeam.id}
        teamName={selectedTeam.name}
        viewerUserId={data.viewerUserId}
        canManage={selectedTeam.manageAccounts}
        canManageApiKeys={selectedTeam.manageApiKeys}
        transferTeams={data.transferTeams}
        claude={data.claude}
        native={data.native}
        shared={data.shared}
      />

      <MachineUsageSection teamName={selectedTeam.name} usage={data.machineUsage} />
    </CoderouterPageFrame>
  );
}

export function TeamMetricsSection({
  metrics,
  teamName,
}: {
  readonly metrics: CoderouterTeamMetrics;
  readonly teamName: string;
}) {
  const t = useTranslations("dashboard.coderouter.metrics");
  const locale = useLocale();
  if (metrics.kind === "unavailable") {
    return (
      <section className="mb-4 border border-border p-3">
        <h2 className="text-sm font-medium">{t("title")}</h2>
        <p className="mt-1 text-xs text-muted">{t("unavailable")}</p>
      </section>
    );
  }

  const number = new Intl.NumberFormat(locale, { notation: "compact", maximumFractionDigits: 1 });
  const currency = new Intl.NumberFormat(locale, {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  });
  const percent = new Intl.NumberFormat(locale, { style: "percent", maximumFractionDigits: 0 });
  const unpricedShare = metrics.totals.totalTokens > 0
    ? metrics.totals.unpricedTokens / metrics.totals.totalTokens
    : 0;
  const maxDailyTokens = Math.max(1, ...metrics.daily.map((day) => day.totalTokens));
  const tokensLabel = t("tokens");

  return (
    <section className="mb-4 border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-sm font-medium">{t("title")}</h2>
          <p className="mt-1 text-xs text-muted">{t("scope", { team: teamName })}</p>
        </div>
        <span className="font-mono text-[11px] text-muted">
          {t("period", { days: metrics.periodDays })}
        </span>
      </div>

      <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        <MetricCard label={tokensLabel} value={number.format(metrics.totals.totalTokens)} />
        <MetricCard label={t("inputTokens")} value={number.format(metrics.totals.inputTokens)} />
        <MetricCard label={t("outputTokens")} value={number.format(metrics.totals.outputTokens)} />
        <MetricCard label={t("apiEquivalent")} value={currency.format(metrics.totals.apiEquivalentUsd)} />
      </div>

      <div
        className="mt-3 flex h-24 items-end gap-px border border-border px-2 pt-2"
        role="img"
        aria-label={t("chartLabel")}
      >
        {metrics.daily.map((day) => {
          const height = day.totalTokens === 0
            ? 0
            : Math.max(3, (day.totalTokens / maxDailyTokens) * 100);
          return (
            <div
              key={day.day}
              className="min-w-0 flex-1 bg-foreground/70"
              style={{ height: `${height}%` }}
              title={`${day.day}: ${number.format(day.totalTokens)} ${tokensLabel.toLowerCase()}`}
            />
          );
        })}
      </div>

      <p className="mt-2 text-[11px] leading-5 text-muted">{t("privacy")}</p>
      <p className="text-[11px] leading-5 text-muted">
        {t("estimate", { version: metrics.rateCardVersion })}
        {unpricedShare > 0 ? ` ${t("unpriced", { share: percent.format(unpricedShare) })}` : ""}
      </p>
    </section>
  );
}

function MetricCard({ label, value }: { readonly label: string; readonly value: string }) {
  return (
    <div className="border border-border p-2">
      <div className="text-[11px] text-muted">{label}</div>
      <div className="mt-1 font-mono text-lg tabular-nums">{value}</div>
    </div>
  );
}

export function MachineUsageSection({
  teamName,
  usage,
}: {
  readonly teamName: string;
  readonly usage: MachineUsage;
}) {
  const t = useTranslations("dashboard.coderouter.machines");
  const days = usage.periodDays;
  return (
    <section className="mb-4 border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-sm font-medium">{t("title")}</h2>
          <p className="mt-1 text-xs text-muted">{t("description", { team: teamName, days })}</p>
        </div>
      </div>
      {usage.kind === "unavailable" ? (
        <p className="mt-2 text-xs text-muted">{t("unavailable")}</p>
      ) : usage.machines.length === 0 ? (
        <p className="mt-2 text-xs text-muted">{t("empty", { days })}</p>
      ) : (
        <MachineTable machines={usage.machines} />
      )}
      <p className="mt-2 text-[11px] leading-5 text-muted">{t("estimateNote")}</p>
    </section>
  );
}

function MachineTable({ machines }: { readonly machines: readonly TeamMachineUsage[] }) {
  const t = useTranslations("dashboard.coderouter.machines");
  const locale = useLocale();
  const number = new Intl.NumberFormat(locale, { notation: "compact", maximumFractionDigits: 1 });
  const currency = new Intl.NumberFormat(locale, {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  });
  return (
    <div className="mt-3 border border-border">
      <div className="hidden grid-cols-[2fr_1fr_1fr] gap-3 border-b border-border px-3 py-2 text-xs text-muted md:grid">
        <div>{t("machineColumn")}</div>
        <div className="text-right">{t("tokensColumn")}</div>
        <div className="text-right">{t("apiEquivalentColumn")}</div>
      </div>
      {machines.map((machine) => (
        <div
          key={machine.vmId}
          className="grid gap-2 border-b border-border px-3 py-2 text-sm last:border-b-0 md:grid-cols-[2fr_1fr_1fr] md:items-center md:gap-3"
        >
          <div className="min-w-0">
            <div className="truncate">{machine.displayName ?? t("unnamed")}</div>
            <div className="truncate font-mono text-[11px] text-muted">{machine.vmId}</div>
          </div>
          <div className="font-mono text-xs tabular-nums md:text-right">
            <span className="mr-2 font-sans text-xs text-muted md:hidden">{t("tokensColumn")}</span>
            {number.format(machine.totals.totalTokens)}
          </div>
          <div className="font-mono text-xs tabular-nums md:text-right">
            <span className="mr-2 font-sans text-xs text-muted md:hidden">{t("apiEquivalentColumn")}</span>
            {currency.format(machine.totals.apiEquivalentUsd)}
          </div>
        </div>
      ))}
    </div>
  );
}
