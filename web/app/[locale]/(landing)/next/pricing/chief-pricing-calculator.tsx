"use client";

import { useMemo, useState } from "react";
import {
  CHIEF_MODELS,
  DEFAULT_CHIEF_USAGE,
  estimateChiefBill,
  recommendChiefPlan,
  type ChiefPlanId,
  type ChiefUsage,
} from "../../../../../services/billing/chiefPricing";

export type ChiefCalculatorLabels = {
  title: string;
  turns: string;
  tokensPerTurn: string;
  workdays: string;
  model: string;
  openModels: string;
  frontierModels: string;
  sandboxHours: string;
  sandboxSize: string;
  parallel: string;
  seats: string;
  tokens: string;
  tokenCost: string;
  /** Contains `{hours}`. */
  sandboxCost: string;
  usage: string;
  included: string;
  overage: string;
  plan: string;
  total: string;
  /** Contains `{plan}`. */
  recommended: string;
  /** Contains `{plan}`. */
  doesNotFit: string;
  assumption: string;
  custom: string;
  planNames: Record<ChiefPlanId, string>;
};

const SIZES = [
  { vcpu: 2, gib: 4 },
  { vcpu: 4, gib: 8 },
  { vcpu: 8, gib: 16 },
  { vcpu: 16, gib: 32 },
  { vcpu: 32, gib: 64 },
] as const;

const usd = (value: number) =>
  new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: value >= 100 ? 0 : 2,
  }).format(value);

const fill = (template: string, key: string, value: string) => template.replace(`{${key}}`, value);

function NumberField({
  label,
  value,
  min,
  max,
  step,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
}) {
  return (
    <label className="grid gap-1.5 text-sm">
      <span className="flex items-baseline justify-between gap-3">
        <span className="text-muted">{label}</span>
        <span className="tabular-nums font-medium">{value.toLocaleString("en-US")}</span>
      </span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(event) => onChange(Number(event.target.value))}
        className="w-full accent-foreground"
      />
    </label>
  );
}

export function ChiefPricingCalculator({ labels }: { labels: ChiefCalculatorLabels }) {
  const [usage, setUsage] = useState<ChiefUsage>(DEFAULT_CHIEF_USAGE);
  const set = <K extends keyof ChiefUsage>(key: K) => (value: ChiefUsage[K]) =>
    setUsage((current) => ({ ...current, [key]: value }));

  const team = usage.seats > 1;
  const recommended = useMemo(() => recommendChiefPlan(usage), [usage]);
  const shown: ChiefPlanId[] = team ? ["team", "enterprise"] : ["free", "pro", "max"];
  const bills = shown.map((id) => estimateChiefBill(id, usage));
  const best = bills.find((bill) => bill.plan === recommended) ?? bills[0];

  return (
    <section aria-labelledby="chief-calculator-title" className="mt-16 border border-border">
      <div className="grid gap-0 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <div className="grid content-start gap-5 border-b border-border p-6 lg:border-b-0 lg:border-r">
          <h2 id="chief-calculator-title" className="text-lg font-medium tracking-tight">
            {labels.title}
          </h2>
          <NumberField label={labels.turns} value={usage.turnsPerDay} min={0} max={300} step={5} onChange={set("turnsPerDay")} />
          <NumberField label={labels.tokensPerTurn} value={usage.tokensPerTurn} min={10_000} max={200_000} step={10_000} onChange={set("tokensPerTurn")} />
          <NumberField label={labels.workdays} value={usage.workdays} min={1} max={31} step={1} onChange={set("workdays")} />
          <label className="grid gap-1.5 text-sm">
            <span className="text-muted">{labels.model}</span>
            <select
              value={usage.modelId}
              onChange={(event) => set("modelId")(event.target.value)}
              className="border border-border bg-background px-2 py-1.5"
            >
              <optgroup label={labels.openModels}>
                {CHIEF_MODELS.filter((m) => m.kind === "open").map((m) => (
                  <option key={m.id} value={m.id}>{m.label}</option>
                ))}
              </optgroup>
              <optgroup label={labels.frontierModels}>
                {CHIEF_MODELS.filter((m) => m.kind === "frontier").map((m) => (
                  <option key={m.id} value={m.id}>{m.label}</option>
                ))}
              </optgroup>
            </select>
          </label>
          <NumberField label={labels.sandboxHours} value={usage.sandboxHoursPerDay} min={0} max={24} step={0.5} onChange={set("sandboxHoursPerDay")} />
          <label className="grid gap-1.5 text-sm">
            <span className="text-muted">{labels.sandboxSize}</span>
            <select
              value={`${usage.sandboxSize.vcpu}`}
              onChange={(event) => {
                const size = SIZES.find((s) => `${s.vcpu}` === event.target.value) ?? SIZES[0];
                set("sandboxSize")({ vcpu: size.vcpu, gib: size.gib });
              }}
              className="border border-border bg-background px-2 py-1.5"
            >
              {SIZES.map((s) => (
                <option key={s.vcpu} value={s.vcpu}>{`${s.vcpu} vCPU / ${s.gib} GB`}</option>
              ))}
            </select>
          </label>
          <NumberField label={labels.parallel} value={usage.parallelSandboxes} min={1} max={40} step={1} onChange={set("parallelSandboxes")} />
          <NumberField label={labels.seats} value={usage.seats} min={1} max={50} step={1} onChange={set("seats")} />
        </div>

        <div className="grid content-start gap-4 p-6" aria-live="polite">
          <p className="text-sm font-medium" data-testid="chief-recommended">
            {fill(labels.recommended, "plan", labels.planNames[recommended])}
          </p>
          <dl className="grid grid-cols-[1fr_auto] gap-x-6 gap-y-2 text-sm tabular-nums">
            <dt className="text-muted">{labels.tokens}</dt>
            <dd className="text-right">{`${best.tokensMillions.toFixed(1)}M`}</dd>
            <dt className="text-muted">{labels.tokenCost}</dt>
            <dd className="text-right">{usd(best.openTokenUsd + best.frontierTokenUsd)}</dd>
            <dt className="text-muted">{fill(labels.sandboxCost, "hours", best.sandboxHours.toLocaleString("en-US"))}</dt>
            <dd className="text-right">{usd(best.sandboxUsd)}</dd>
            <dt className="text-muted">{labels.usage}</dt>
            <dd className="text-right">{usd(best.usageUsd)}</dd>
          </dl>
          <div className="mt-2 grid gap-2">
            {bills.map((bill) => (
              <div
                key={bill.plan}
                className={`grid grid-cols-[1fr_auto] items-baseline gap-x-4 border p-3 text-sm ${bill.plan === recommended ? "border-foreground" : "border-border"}`}
              >
                <span className="font-medium">{labels.planNames[bill.plan]}</span>
                <span className="text-right text-base font-medium tabular-nums">
                  {bill.totalUsd === null ? labels.custom : bill.fits ? usd(bill.totalUsd) : "—"}
                </span>
                {bill.fits && bill.totalUsd !== null ? (
                  <span className="col-span-2 text-xs text-muted tabular-nums">
                    {`${labels.plan} ${usd(bill.planUsd ?? 0)} · ${labels.included} −${usd(bill.includedAppliedUsd)} · ${labels.overage} ${usd(bill.overageUsd)}`}
                  </span>
                ) : bill.totalUsd !== null ? (
                  <span className="col-span-2 text-xs text-muted">
                    {fill(labels.doesNotFit, "plan", labels.planNames[bill.plan])}
                  </span>
                ) : null}
              </div>
            ))}
          </div>
          <p className="text-xs leading-relaxed text-muted">{labels.assumption}</p>
        </div>
      </div>
    </section>
  );
}
