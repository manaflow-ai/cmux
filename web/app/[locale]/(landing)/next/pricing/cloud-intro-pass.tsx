import { FeatureList, PlanCard, pricingActionClassName } from "../../../../components/pricing-shared";
import { CLOUD_INTRO_CHECKOUT_PLAN, CLOUD_INTRO_RENEW_PARAM } from "../../../../../services/billing/cloudIntro";
import { cloudIntroProofStats } from "../../../../../services/billing/cloudIntroProof";
import { cloudIntroOfferFacts, type CloudIntroLayout } from "../../../../../services/billing/cloudIntroOffer";

type Translate = (key: string, values?: Record<string, string | number>) => string;

export type CloudIntroCopy = {
  name: string;
  badge: string;
  price: string;
  period: string;
  summary: string;
  includedTitle: string;
  included: string[];
  renew: string;
  renewHint: string;
  cta: string;
  afterTitle: string;
  after: string;
  who: string;
  proof: { title: string; note: string; stats: { id: string; value: string; label: string }[] };
};

const count = (value: number) => value.toLocaleString("en-US");

/** The pass's strings from the `nextPricing.intro` catalog, every number from cloudIntro.ts. */
export function cloudIntroCopy(t: Translate): CloudIntroCopy {
  const f = cloudIntroOfferFacts();
  const price = `$${count(f.priceUsd)}`;
  const days = f.termDays;
  return {
    name: t("intro.name"),
    badge: t("intro.badge"),
    price: t("intro.price", { price }),
    period: t("intro.period", { days }),
    summary: t("intro.summary", { price, days }),
    includedTitle: t("intro.includedTitle"),
    included: [
      t("intro.included.chief", { vcpu: f.chiefVcpu, gib: f.chiefGib, hours: count(f.chiefHours) }),
      t("intro.included.minutes", { minutes: count(f.machineMinutes), vcpu: f.otherVcpu, gib: f.otherGib }),
      t("intro.included.minuteMeaning", { minutes: count(f.machineMinutes), hours: count(f.machineMinuteHours), vcpu: f.chiefVcpu }),
      t("intro.included.concurrent", { count: f.concurrentMachines }),
      t("intro.included.login"),
      t("intro.included.weekly", { hours: count(f.chiefHoursWeekly), minutes: count(f.machineMinutesWeekly) }),
    ],
    renew: t("intro.renew", { days }),
    renewHint: t("intro.renewHint"),
    cta: t("intro.cta", { price }),
    afterTitle: t("intro.afterTitle", { days }),
    after: t("intro.after", { keepDays: f.keepDays }),
    who: t("intro.who"),
    proof: {
      title: t("proof.title"),
      note: t("proof.note", { count: f.concurrentMachines }),
      stats: cloudIntroProofStats().map((stat) => ({
        id: stat.id,
        value: t("proof.seconds", { seconds: stat.seconds }),
        label: t(`proof.${stat.id}`, { machines: stat.machines ?? 0 }),
      })),
    },
  };
}

/**
 * The buy form. A plain GET: the checkbox is off by default and, like any
 * unticked checkbox, sends nothing, so `renew=1` reaches checkout only when
 * the buyer ticks it.
 */
function CloudIntroBuyForm({ copy, size = "default" }: { copy: CloudIntroCopy; size?: "default" | "compact" }) {
  return (
    <form method="get" action="/api/billing/checkout" data-testid="cloud-intro-form" className="space-y-3">
      <input type="hidden" name="plan" value={CLOUD_INTRO_CHECKOUT_PLAN} />
      <label className="flex items-start gap-2.5 text-sm">
        <input type="checkbox" name={CLOUD_INTRO_RENEW_PARAM} value="1" className="mt-1" />
        <span>
          {copy.renew}
          <span className="block text-xs text-muted">{copy.renewHint}</span>
        </span>
      </label>
      <button
        type="submit"
        className={pricingActionClassName("primary", size)}
        style={{ color: "var(--button-foreground, var(--background))" }}
      >
        {copy.cta}
      </button>
    </form>
  );
}

function CloudIntroFinePrint({ copy }: { copy: CloudIntroCopy }) {
  return (
    <div className="mt-5 space-y-3 text-sm leading-relaxed">
      <div className="border-l border-foreground pl-3">
        <p className="font-medium">{copy.afterTitle}</p>
        <p className="mt-1 text-muted">{copy.after}</p>
      </div>
      <p className="text-xs text-muted">{copy.who}</p>
    </div>
  );
}

/** Three measured numbers where the pass is sold; each is from cloudIntroProof.ts. */
function CloudIntroProof({ copy }: { copy: CloudIntroCopy }) {
  return (
    <div data-testid="cloud-intro-proof" className="mt-5">
      <p className="text-xs font-medium text-muted">{copy.proof.title}</p>
      <dl className="mt-2 grid gap-4 sm:grid-cols-3">
        {copy.proof.stats.map((stat) => (
          <div key={stat.id} data-proof={stat.id} className="border-l border-foreground pl-3">
            <dt className="text-2xl font-medium tabular-nums tracking-tight">{stat.value}</dt>
            <dd className="mt-1 text-xs leading-relaxed text-muted">{stat.label}</dd>
          </div>
        ))}
      </dl>
      <p className="mt-2 text-xs text-muted">{copy.proof.note}</p>
    </div>
  );
}

const badgeClass = "border border-border px-2 py-1 text-xs font-medium";

/** (a) A slim band above the plan cards. */
function CloudIntroBand({ copy }: { copy: CloudIntroCopy }) {
  return (
    <section data-cloud-intro="a" aria-label={copy.name} className="mt-12 border border-foreground p-5">
      <div className="grid gap-5 md:grid-cols-[1fr_auto] md:items-start">
        <div>
          <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h2 className="text-sm font-medium tracking-tight">{copy.name}</h2>
            <span className="text-2xl font-medium tabular-nums tracking-tight">{copy.price}</span>
            <span className="text-sm text-muted">{copy.period}</span>
          </div>
          <p className="mt-2 max-w-2xl text-sm leading-relaxed text-muted">{copy.summary}</p>
          <CloudIntroProof copy={copy} />
          <details className="mt-3 text-sm">
            <summary className="cursor-pointer font-medium">{copy.includedTitle}</summary>
            <FeatureList items={copy.included} />
            <CloudIntroFinePrint copy={copy} />
          </details>
        </div>
        <div className="md:w-64">
          <CloudIntroBuyForm copy={copy} size="compact" />
        </div>
      </div>
    </section>
  );
}

/** (b) A full card, first in the plan row. */
export function CloudIntroCard({ copy }: { copy: CloudIntroCopy }) {
  return (
    <div data-cloud-intro="b" className="contents">
      <PlanCard name={copy.name} price={copy.price} period={copy.period} badge={<span className={badgeClass}>{copy.badge}</span>}>
        <p className="mb-4 text-sm leading-relaxed text-muted">{copy.summary}</p>
        <CloudIntroBuyForm copy={copy} />
        <CloudIntroProof copy={copy} />
        <FeatureList items={copy.included} />
        <CloudIntroFinePrint copy={copy} />
      </PlanCard>
    </div>
  );
}

/** (c) A hero block at the top with the checklist of what is inside. */
function CloudIntroHero({ copy }: { copy: CloudIntroCopy }) {
  return (
    <section data-cloud-intro="c" aria-label={copy.name} className="mb-14 border border-foreground p-6 sm:p-8">
      <span className={badgeClass}>{copy.badge}</span>
      <h2 className="mt-4 text-2xl font-medium tracking-tight sm:text-3xl">{copy.name}</h2>
      <p className="mt-3 max-w-2xl text-[15px] leading-relaxed text-muted">{copy.summary}</p>
      <CloudIntroProof copy={copy} />
      <div className="mt-6 grid gap-8 md:grid-cols-[1fr_18rem]">
        <div>
          <p className="text-sm font-medium">{copy.includedTitle}</p>
          <FeatureList items={copy.included} />
        </div>
        <div>
          <div className="mb-4 flex items-baseline gap-1.5">
            <span className="text-3xl font-medium tabular-nums tracking-tight">{copy.price}</span>
            <span className="text-sm text-muted">{copy.period}</span>
          </div>
          <CloudIntroBuyForm copy={copy} />
          <CloudIntroFinePrint copy={copy} />
        </div>
      </div>
    </section>
  );
}

/** Where on the page a layout goes: the band and hero stand alone; the card joins the plan row. */
export function CloudIntroPass({ copy, layout, slot }: { copy: CloudIntroCopy; layout: CloudIntroLayout; slot: "top" | "beforePlans" }) {
  if (slot === "top" && layout === "c") return <CloudIntroHero copy={copy} />;
  if (slot === "beforePlans" && layout === "a") return <CloudIntroBand copy={copy} />;
  return null;
}
