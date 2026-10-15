"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import type {
  PaywallLab,
  PaywallLabExperiment,
  PaywallLabVariant,
} from "@/orpc/server/dashboard/schemas/ops";
import { EmptyState } from "../../components/page-states";
import { paywallLabQuery, usePaywallLabSetPaused } from "../../queries/ops";
import { PaywallLabFrame } from "./paywall-lab-frame";
import { IosPaywallPreview, WebPricingVariantPreview } from "./paywall-lab-previews";

/** `/dashboard/ops/paywall-lab`: every paywall and pricing experiment. Staff only. */
export function PaywallLabScreen() {
  const { data } = useSuspenseQuery(paywallLabQuery);
  return <PaywallLabView lab={data} />;
}

export function PaywallLabView({ lab }: { readonly lab: PaywallLab }) {
  const t = useTranslations("opsPaywallLab");
  return (
    <PaywallLabFrame>
      {lab.experiments.length === 0 ? (
        <EmptyState title={t("empty")} />
      ) : (
        <div className="space-y-12">
          {lab.experiments.map((experiment) => (
            <ExperimentSection key={experiment.key} experiment={experiment} lab={lab} />
          ))}
        </div>
      )}
    </PaywallLabFrame>
  );
}

function ExperimentSection({ experiment, lab }: { readonly experiment: PaywallLabExperiment; readonly lab: PaywallLab }) {
  const t = useTranslations("opsPaywallLab");
  return (
    <section data-testid={`paywall-lab-${experiment.key}`} className="space-y-4">
      <ExperimentHeader experiment={experiment} />
      <VariantTable experiment={experiment} />
      <p className="text-xs text-muted">{lab.trialAvailable ? t("trialAvailable") : t("trialNone")}</p>
      <div>
        <h3 className="mb-2 text-xs font-medium text-muted">{t("previewsTitle")}</h3>
        <p className="mb-3 text-xs text-muted">
          {experiment.platform === "web" ? t("webPreviewNote") : t("iosPreviewNote")}
        </p>
        <div className={experiment.platform === "web" ? "space-y-4" : "grid gap-4 md:grid-cols-2 lg:grid-cols-3"}>
          {experiment.variants.map((variant) => (
            <VariantPreviewCard key={variant.variant} variant={variant} vaultEnabled={lab.vaultEnabled} />
          ))}
        </div>
      </div>
      <ChangeLog experiment={experiment} />
    </section>
  );
}

function ExperimentHeader({ experiment }: { readonly experiment: PaywallLabExperiment }) {
  const t = useTranslations("opsPaywallLab");
  const locale = useLocale();
  const paused = experiment.flagState === "paused";
  return (
    <div className="space-y-2 border-b border-border pb-3">
      <div className="flex flex-wrap items-center gap-3">
        <h2 className="font-mono text-sm font-medium">{experiment.key}</h2>
        <span className="text-xs text-muted">{t(`platform.${experiment.platform === "web" ? "web" : "ios"}`)}</span>
        <span
          data-testid="paywall-lab-flag-state"
          className={`border px-1.5 text-xs ${experiment.flagState === "live" ? "border-green-600/50" : "border-amber-500/60"}`}
        >
          {t(`flag.${experiment.flagState}`)}
        </span>
        <div className="ml-auto flex items-center gap-3">
          {experiment.hasReport ? (
            <a
              className="text-xs underline underline-offset-2"
              href={`/api/admin/paywall-lab/report?experiment=${encodeURIComponent(experiment.key)}`}
              target="_blank"
              rel="noreferrer"
            >
              {t("report")}
            </a>
          ) : (
            <span className="text-xs text-muted">{t("noReport")}</span>
          )}
          {experiment.flagState === "live" || paused ? <KillSwitch experiment={experiment} paused={paused} /> : null}
        </div>
      </div>
      <p className="text-xs text-muted">
        {experiment.lastRunAt ? t("lastRun", { time: formatTime(experiment.lastRunAt, locale) }) : t("noRun")}
        {" "}
        {t("primary", { label: experiment.primaryLabel })}
      </p>
      <p className={`text-xs ${experiment.srm.mismatch ? "text-red-600" : "text-muted"}`} data-testid="paywall-lab-srm">
        {experiment.srm.tested
          ? t("srmTested", { p: (experiment.srm.pValue ?? 0).toExponential(2), mismatch: experiment.srm.mismatch ? "true" : "false" })
          : t("srmNotTested", { reason: experiment.srm.note ?? "" })}
      </p>
      {experiment.halted ? <p className="text-xs font-medium text-red-600">{t("halted")}</p> : null}
      {experiment.reasons.length > 0 ? (
        <details className="text-xs">
          <summary className="cursor-pointer text-muted">{t("reasonsTitle")}</summary>
          <ul className="mt-1 list-disc space-y-0.5 pl-5">
            {experiment.reasons.map((reason) => <li key={reason}>{reason}</li>)}
          </ul>
        </details>
      ) : null}
    </div>
  );
}

function KillSwitch({ experiment, paused }: { readonly experiment: PaywallLabExperiment; readonly paused: boolean }) {
  const t = useTranslations("opsPaywallLab");
  const mutation = usePaywallLabSetPaused();
  const toggle = () => {
    const message = paused
      ? t("resumeConfirm", { experiment: experiment.key })
      : t("pauseConfirm", { experiment: experiment.key, control: experiment.controlVariant });
    if (!window.confirm(message)) return;
    mutation.mutate({ experiment: experiment.key, paused: !paused });
  };
  return (
    <span className="flex items-center gap-2">
      {mutation.isError ? <span className="text-xs text-red-600">{t("toggleFailed")}</span> : null}
      <button
        type="button"
        data-testid="paywall-lab-kill-switch"
        onClick={toggle}
        disabled={mutation.isPending}
        className={`border px-2 py-1 text-xs font-medium ${paused ? "border-border" : "border-red-500/60 text-red-600"}`}
      >
        {paused ? t("resume") : t("pause")}
      </button>
    </span>
  );
}

function VariantTable({ experiment }: { readonly experiment: PaywallLabExperiment }) {
  const t = useTranslations("opsPaywallLab");
  const proposed = experiment.variants.some((variant) => variant.proposedTrafficPercent !== null);
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left text-xs tabular-nums">
        <thead className="text-muted">
          <tr className="border-b border-border">
            <th className="py-1.5 pr-3 font-medium">{t("column.variant")}</th>
            <th className="py-1.5 pr-3 font-medium">{t("column.status")}</th>
            <th className="py-1.5 pr-3 font-medium">{t("column.traffic")}</th>
            {proposed ? <th className="py-1.5 pr-3 font-medium">{t("column.next")}</th> : null}
            <th className="py-1.5 pr-3 font-medium">{t("column.exposed")}</th>
            <th className="py-1.5 pr-3 font-medium">{t("column.converted")}</th>
            <th className="py-1.5 pr-3 font-medium">{t("column.rate")}</th>
            <th className="py-1.5 pr-3 font-medium">{t("column.pBest")}</th>
            {experiment.secondaryMetrics.map((metric) => <th key={metric.key} className="py-1.5 pr-3 font-medium" title={metric.label}>{metric.key}</th>)}
            {experiment.guardrailMetrics.map((metric) => <th key={metric.key} className="py-1.5 pr-3 font-medium" title={metric.label}>{metric.key}</th>)}
          </tr>
        </thead>
        <tbody>
          {experiment.variants.map((variant) => (
            <VariantRow key={variant.variant} variant={variant} experiment={experiment} proposed={proposed} />
          ))}
        </tbody>
      </table>
    </div>
  );
}

function VariantRow({ variant, experiment, proposed }: { readonly variant: PaywallLabVariant; readonly experiment: PaywallLabExperiment; readonly proposed: boolean }) {
  const t = useTranslations("opsPaywallLab");
  return (
    <tr className="border-b border-border/60" data-testid={`paywall-lab-row-${variant.variant}`}>
      <td className="py-1.5 pr-3 font-mono">{variant.variant}</td>
      <td className="py-1.5 pr-3">{t(`status.${variant.status}`)}</td>
      <td className="py-1.5 pr-3">{variant.trafficPercent}%</td>
      {proposed ? <td className="py-1.5 pr-3">{variant.proposedTrafficPercent === null ? "" : `${variant.proposedTrafficPercent}%`}</td> : null}
      <td className="py-1.5 pr-3">{variant.exposures ?? "–"}</td>
      <td className="py-1.5 pr-3">{variant.conversions ?? "–"}</td>
      <td className="py-1.5 pr-3">{rate(variant.conversions, variant.exposures)}</td>
      <td className="py-1.5 pr-3">{variant.probabilityBest === null ? "–" : variant.probabilityBest.toFixed(3)}</td>
      {experiment.secondaryMetrics.map((metric) => <td key={metric.key} className="py-1.5 pr-3">{variant.secondary[metric.key] ?? "–"}</td>)}
      {experiment.guardrailMetrics.map((metric) => <td key={metric.key} className="py-1.5 pr-3">{variant.guardrails[metric.key] ?? "–"}</td>)}
    </tr>
  );
}

function VariantPreviewCard({ variant, vaultEnabled }: { readonly variant: PaywallLabVariant; readonly vaultEnabled: boolean }) {
  const t = useTranslations("opsPaywallLab");
  return (
    <article className="border border-border" data-testid={`paywall-lab-preview-${variant.variant}`}>
      <header className="flex flex-wrap items-baseline gap-2 border-b border-border px-3 py-2 text-xs">
        <span className="font-mono font-medium">{variant.variant}</span>
        <span className="text-muted">{variant.name}</span>
        <span className="ml-auto text-muted">{variant.trafficPercent}% · {t(`status.${variant.status}`)}</span>
        {variant.hypothesis ? <p className="w-full text-muted">{variant.hypothesis}</p> : null}
      </header>
      {variant.payloadErrors.length > 0 ? (
        <div className="px-3 py-2 text-xs text-red-600">
          <p className="font-medium">{t("invalidCopy")}</p>
          <ul className="list-disc pl-5">{variant.payloadErrors.map((error) => <li key={error}>{error}</li>)}</ul>
        </div>
      ) : null}
      <div className="p-3">
        {variant.preview?.kind === "web" ? (
          <WebPricingVariantPreview presentation={variant.preview.presentation} vaultEnabled={vaultEnabled} />
        ) : variant.preview?.kind === "ios" ? (
          <IosPaywallPreview config={variant.preview.config} />
        ) : null}
      </div>
    </article>
  );
}

function ChangeLog({ experiment }: { readonly experiment: PaywallLabExperiment }) {
  const t = useTranslations("opsPaywallLab");
  const locale = useLocale();
  return (
    <div>
      <h3 className="mb-2 text-xs font-medium text-muted">{t("changeLogTitle")}</h3>
      {experiment.changeLog.length === 0 ? (
        <p className="text-xs text-muted">{t("changeLogEmpty")}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-xs" data-testid="paywall-lab-change-log">
            <thead className="text-muted">
              <tr className="border-b border-border">
                <th className="py-1.5 pr-3 font-medium">{t("changeColumn.when")}</th>
                <th className="py-1.5 pr-3 font-medium">{t("changeColumn.kind")}</th>
                <th className="py-1.5 pr-3 font-medium">{t("changeColumn.variant")}</th>
                <th className="py-1.5 pr-3 font-medium">{t("changeColumn.reason")}</th>
                <th className="py-1.5 pr-3 font-medium">{t("changeColumn.actor")}</th>
              </tr>
            </thead>
            <tbody>
              {experiment.changeLog.map((change, index) => (
                <tr key={`${change.changedAt}-${index}`} className="border-b border-border/60 align-top">
                  <td className="whitespace-nowrap py-1.5 pr-3">{formatTime(change.changedAt, locale)}</td>
                  <td className="py-1.5 pr-3 font-mono">{change.kind}</td>
                  <td className="py-1.5 pr-3 font-mono">{change.variant ?? ""}</td>
                  <td className="py-1.5 pr-3">{change.reason}</td>
                  <td className="py-1.5 pr-3">{change.actor}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function rate(conversions: number | null, exposures: number | null): string {
  if (conversions === null || !exposures) return "–";
  return `${((conversions / exposures) * 100).toFixed(1)}%`;
}

function formatTime(iso: string, locale: string): string {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(new Date(iso));
}
