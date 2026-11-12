"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import type { ReactNode } from "react";
import type { CloudVmHealth, CloudVmHealthReport } from "@/orpc/server/dashboard/schemas/ops";
import { EmptyState } from "../../components/page-states";
import { cloudVmHealthQuery } from "../../queries/ops";
import { CloudVmHealthFrame } from "./cloud-vm-health-frame";

type Owners = CloudVmHealth["owners"];
type Owner = CloudVmHealthReport["hung"][number]["owner"];

/** `/dashboard/ops/cloud-vms`: the newest stored health sweep. Staff only. */
export function CloudVmHealthScreen() {
  const { data } = useSuspenseQuery(cloudVmHealthQuery);
  return <CloudVmHealthView health={data} />;
}

export function CloudVmHealthView({ health }: { readonly health: CloudVmHealth }) {
  const t = useTranslations("opsCloudVmHealth");
  const { snapshot, report } = health;
  if (!snapshot || !report) {
    return (
      <CloudVmHealthFrame>
        <EmptyState title={t("noSnapshotTitle")} body={t("noSnapshotBody")} />
      </CloudVmHealthFrame>
    );
  }
  return (
    <CloudVmHealthFrame>
      <div className="space-y-6">
        <Summary snapshot={snapshot} report={report} />
        <HungSection report={report} owners={health.owners} />
        <StuckSection report={report} owners={health.owners} />
        <DriftSection report={report} owners={health.owners} />
        <TlsSection report={report} owners={health.owners} />
        {report.errors.length > 0 ? <ErrorsSection report={report} /> : null}
      </div>
    </CloudVmHealthFrame>
  );
}

function Summary({ snapshot, report }: { readonly snapshot: NonNullable<CloudVmHealth["snapshot"]>; readonly report: CloudVmHealthReport }) {
  const t = useTranslations("opsCloudVmHealth");
  const locale = useLocale();
  const needed = report.attention.needed || snapshot.stale;
  return (
    <section data-testid="cloud-vm-health-summary" className="space-y-3">
      <div className={`border p-3 ${needed ? "border-red-500/60 bg-red-500/5" : "border-green-600/50 bg-green-600/5"}`}>
        <p className="text-sm font-medium" data-testid="cloud-vm-health-attention">
          {needed ? t("attentionYes") : t("attentionNo")}
        </p>
        {snapshot.stale || report.attention.reasons.length > 0 ? (
          <ul className="mt-2 list-disc space-y-0.5 pl-5 text-xs">
            {snapshot.stale ? <li>{t("reason.stale", { age: formatAge(snapshot.ageSeconds, locale) })}</li> : null}
            {report.attention.reasons.map((reason) => (
              <li key={reason.code}>{t(`reason.${reason.code}`, reasonValues(reason))}</li>
            ))}
          </ul>
        ) : null}
        <p className="mt-2 text-xs text-muted">
          {t("sweptAt", {
            age: formatAge(snapshot.ageSeconds, locale),
            seconds: Math.round(report.durationMs / 1000),
          })}
        </p>
      </div>
      <div className="grid border border-border sm:grid-cols-3 lg:grid-cols-6">
        {Object.entries(report.stateCounts).sort(([a], [b]) => a.localeCompare(b)).map(([state, count]) => (
          <Metric key={state} label={state} value={count.toLocaleString(locale)} />
        ))}
      </div>
      <p className="font-mono text-xs text-muted">
        {Object.entries(report.workloadCounts).map(([workload, count]) => `${count.toLocaleString(locale)} ${workload}`).join(" · ")}
      </p>
      <p className="text-xs text-muted">
        {t("coverage", {
          probed: report.coverage.probed,
          running: report.coverage.running,
          skippedBudget: report.coverage.skippedBudget,
          skippedIdle: report.coverage.skippedIdle,
          probeErrors: report.coverage.probeErrors,
        })}
      </p>
    </section>
  );
}

function reasonValues(reason: CloudVmHealthReport["attention"]["reasons"][number]): Record<string, number> {
  return Object.fromEntries(Object.entries(reason).filter(([key]) => key !== "code")) as Record<string, number>;
}

function HungSection({ report, owners }: { readonly report: CloudVmHealthReport; readonly owners: Owners }) {
  const t = useTranslations("opsCloudVmHealth");
  const locale = useLocale();
  return (
    <Section title={t("hung.title", { count: report.hung.length })} body={t("hung.body")} testId="cloud-vm-health-hung">
      {report.hung.length === 0 ? <None /> : (
        <Table headers={[t("col.vm"), t("col.workload"), t("col.owner"), t("col.image"), t("col.firstSeenHung"), t("col.updated"), t("col.detail")]}>
          {report.hung.map((vm) => (
            <tr key={vm.vmId} className="border-t border-border align-top">
              <Cell mono>{vm.vmId}</Cell>
              <Cell>{vm.workload}</Cell>
              <Cell><OwnerCell owner={vm.owner} owners={owners} /></Cell>
              <Cell mono>
                {vm.snapshot ?? "—"}
                <span className="block text-muted">{t("size", sizeValues(vm.size))}</span>
              </Cell>
              <Cell>{formatTime(vm.firstSeenHungAt, locale)}</Cell>
              <Cell>
                {formatTime(vm.providerUpdatedAt, locale)}
                {vm.dbUpdatedAt ? <span className="block text-muted">{t("dbUpdated", { time: formatTime(vm.dbUpdatedAt, locale) })}</span> : null}
              </Cell>
              <Cell mono>{vm.detail}</Cell>
            </tr>
          ))}
        </Table>
      )}
    </Section>
  );
}

function StuckSection({ report, owners }: { readonly report: CloudVmHealthReport; readonly owners: Owners }) {
  const t = useTranslations("opsCloudVmHealth");
  const locale = useLocale();
  return (
    <Section title={t("stuck.title", { count: report.stuck.length })} body={t("stuck.body")} testId="cloud-vm-health-stuck">
      {report.stuck.length === 0 ? <None /> : (
        <Table headers={[t("col.vm"), t("col.state"), t("col.source"), t("col.workload"), t("col.owner"), t("col.since")]}>
          {report.stuck.map((vm) => (
            <tr key={`${vm.source}:${vm.vmId}`} className="border-t border-border align-top">
              <Cell mono>{vm.vmId}</Cell>
              <Cell>{vm.state}</Cell>
              <Cell>{t(`source.${vm.source}`)}</Cell>
              <Cell>{vm.workload}</Cell>
              <Cell><OwnerCell owner={vm.owner} owners={owners} /></Cell>
              <Cell>{formatTime(vm.since, locale)} <span className="text-muted">({formatAge(vm.minutes * 60, locale)})</span></Cell>
            </tr>
          ))}
        </Table>
      )}
    </Section>
  );
}

function DriftSection({ report, owners }: { readonly report: CloudVmHealthReport; readonly owners: Owners }) {
  const t = useTranslations("opsCloudVmHealth");
  const locale = useLocale();
  return (
    <Section title={t("drift.title", { count: report.drift.length })} body={t("drift.body")} testId="cloud-vm-health-drift">
      {report.drift.length === 0 ? <None /> : (
        <Table headers={[t("col.vm"), t("col.drift"), t("col.dbStatus"), t("col.providerState"), t("col.owner"), t("col.updated")]}>
          {report.drift.map((vm) => (
            <tr key={`${vm.kind}:${vm.vmId}`} className="border-t border-border align-top">
              <Cell mono>{vm.vmId}</Cell>
              <Cell>{t(`driftKind.${vm.kind}`)}</Cell>
              <Cell>{vm.dbStatus ?? "—"}</Cell>
              <Cell>{vm.providerState ?? "—"}</Cell>
              <Cell><OwnerCell owner={vm.owner} owners={owners} /></Cell>
              <Cell>{formatTime(vm.dbUpdatedAt ?? vm.providerUpdatedAt, locale)}</Cell>
            </tr>
          ))}
        </Table>
      )}
    </Section>
  );
}

function TlsSection({ report, owners }: { readonly report: CloudVmHealthReport; readonly owners: Owners }) {
  const t = useTranslations("opsCloudVmHealth");
  const locale = useLocale();
  const tls = report.tls;
  if (!tls) {
    return <Section title={t("tls.title")} body={t("tls.unavailable")} testId="cloud-vm-health-tls" />;
  }
  const over = tls.totalCount - tls.limit;
  return (
    <Section title={t("tls.title")} body={t("tls.body")} testId="cloud-vm-health-tls">
      <p className={`text-sm font-medium ${over >= 0 ? "text-red-600" : ""}`}>
        {t("tls.usage", { count: tls.totalCount, limit: tls.limit })}
        {over >= 0 ? ` ${t("tls.over", { over })}` : ""}
      </p>
      {!tls.complete ? <p className="text-xs text-muted">{t("tls.partial", { listed: tls.listed })}</p> : null}
      <div className="mt-2 grid border border-border sm:grid-cols-3 lg:grid-cols-6">
        {Object.entries(tls.byOwner).sort(([, a], [, b]) => b - a).map(([owner, count]) => (
          <Metric key={owner} label={tlsOwnerLabel(owner, t)} value={count.toLocaleString(locale)} />
        ))}
      </div>
      <h3 className="mt-4 text-xs font-medium">
        {t("tls.pausedTitle", { days: tls.pausedOverDays, vms: tls.pausedHolders.vmCount, rules: tls.pausedHolders.ruleCount })}
      </h3>
      {tls.pausedHolders.top.length === 0 ? <None /> : (
        <Table headers={[t("col.vm"), t("col.workload"), t("col.owner"), t("col.pausedSince"), t("col.rules")]}>
          {tls.pausedHolders.top.map((holder) => (
            <tr key={holder.vmId} className="border-t border-border align-top">
              <Cell mono>{holder.vmId}</Cell>
              <Cell>{holder.workload}</Cell>
              <Cell><OwnerCell owner={holder.owner} owners={owners} /></Cell>
              <Cell>{formatTime(holder.pausedSince, locale)}</Cell>
              <Cell mono>{holder.rules}</Cell>
            </tr>
          ))}
        </Table>
      )}
    </Section>
  );
}

function tlsOwnerLabel(owner: string, t: ReturnType<typeof useTranslations<"opsCloudVmHealth">>): string {
  switch (owner) {
    case "account_level":
    case "vpc_unattributed":
    case "unknown_vm":
    case "managed":
      return t(`tlsOwner.${owner}`);
    default:
      return owner;
  }
}

function ErrorsSection({ report }: { readonly report: CloudVmHealthReport }) {
  const t = useTranslations("opsCloudVmHealth");
  return (
    <Section title={t("errors.title")} body={t("errors.body")} testId="cloud-vm-health-errors">
      <ul className="space-y-1 font-mono text-xs">
        {report.errors.map((error, index) => (
          <li key={`${error.stage}:${index}`}>{error.stage}: {error.message}</li>
        ))}
      </ul>
    </Section>
  );
}

function OwnerCell({ owner, owners }: { readonly owner: Owner; readonly owners: Owners }) {
  const t = useTranslations("opsCloudVmHealth");
  if (!owner) return <span className="text-muted">{t("noOwner")}</span>;
  const contact = owners[owner.userId];
  return (
    <span>
      <span className="block">{contact?.email ?? owner.userId}</span>
      {owner.teamId && owner.teamId !== owner.userId ? <span className="block font-mono text-muted">{owner.teamId}</span> : null}
    </span>
  );
}

function Section({ title, body, testId, children }: { readonly title: string; readonly body: string; readonly testId: string; readonly children?: ReactNode }) {
  return (
    <section data-testid={testId}>
      <h2 className="text-sm font-medium">{title}</h2>
      <p className="mt-1 max-w-3xl text-xs text-muted">{body}</p>
      {children ? <div className="mt-2">{children}</div> : null}
    </section>
  );
}

function None() {
  const t = useTranslations("opsCloudVmHealth");
  return <p className="text-xs text-muted">{t("none")}</p>;
}

function Table({ headers, children }: { readonly headers: readonly string[]; readonly children: ReactNode }) {
  return (
    <div className="overflow-x-auto border border-border">
      <table className="w-full text-left text-xs">
        <thead className="text-muted">
          <tr>{headers.map((header) => <th key={header} className="px-2 py-1.5 font-medium">{header}</th>)}</tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  );
}

function Cell({ children, mono }: { readonly children: ReactNode; readonly mono?: boolean }) {
  return <td className={`px-2 py-1.5 ${mono ? "font-mono break-all" : ""}`}>{children}</td>;
}

function Metric({ label, value }: { readonly label: string; readonly value: string }) {
  return (
    <div className="border-b border-border p-3 sm:border-r">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-2 font-mono text-xs tabular-nums">{value}</p>
    </div>
  );
}

/** Size in the units the provider bills: vCPU, GiB of memory, GB of disk; "?" when unknown. */
function sizeValues(size: CloudVmHealthReport["hung"][number]["size"]): Record<string, string> {
  return {
    cpu: size.cpu === null ? "?" : String(size.cpu),
    memory: size.memoryMib === null ? "?" : String(Math.round(size.memoryMib / 1024)),
    disk: size.storageMib === null ? "?" : String(Math.round(size.storageMib / 1024)),
  };
}

function formatTime(iso: string | null, locale: string): string {
  if (!iso) return "—";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" });
}

/** "3 minutes ago" in the viewer's language, using the largest whole unit. */
function formatAge(seconds: number, locale: string): string {
  const format = new Intl.RelativeTimeFormat(locale, { numeric: "always" });
  if (seconds < 90) return format.format(-Math.round(seconds), "second");
  if (seconds < 90 * 60) return format.format(-Math.round(seconds / 60), "minute");
  if (seconds < 36 * 3600) return format.format(-Math.round(seconds / 3600), "hour");
  return format.format(-Math.round(seconds / 86400), "day");
}
