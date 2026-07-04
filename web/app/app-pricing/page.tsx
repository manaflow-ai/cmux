import type { CSSProperties } from "react";
import { getStackServerApp, isStackConfigured } from "../lib/stack";
import { FREE_PLAN_ID, resolveProPlanStatus } from "../../services/billing/pro";

const CHECKOUT_URL = "/api/billing/checkout";

export const dynamic = "force-dynamic";

export default async function AppPricingPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const snapshot = await currentPlanSnapshot();
  const params = await searchParams;
  const banner = appPricingBanner(params);
  const appearance = appPricingAppearance(params);

  return (
    <main
      className="min-h-screen w-full overflow-x-hidden px-5 py-5 text-foreground sm:px-7 sm:py-7"
      data-app-pricing-appearance={appearance}
      style={appPricingStyle(appearance)}
    >
      <div className="mx-auto flex w-full max-w-5xl flex-col gap-6">
        {banner ? <BillingBanner banner={banner} /> : null}

        <header className="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted">
              cmux Pro
            </p>
            <h1 className="mt-1 text-2xl font-semibold tracking-tight sm:text-3xl">
              Upgrade when Cloud VMs become part of your daily loop.
            </h1>
          </div>
          <CurrentPill snapshot={snapshot} />
        </header>

        <section className="grid gap-4 md:grid-cols-2">
          <PlanPanel
            name="Free"
            price="$0"
            period="/month"
            current={snapshot.planId === FREE_PLAN_ID}
            cta={snapshot.planId === FREE_PLAN_ID ? "Current plan" : "Included"}
            disabled
            features={[
              "Native Ghostty-based terminal",
              "Claude Code, Codex, Gemini, and any local CLI agent",
              "Vertical tabs, split panes, browser panels, and notifications",
              "Local session history and one Cloud VM trial",
            ]}
          />

          <PlanPanel
            name="Pro"
            price="$30"
            period="/month"
            current={snapshot.isPro}
            cta={snapshot.isPro ? "Current plan" : snapshot.authenticated ? "Upgrade to Pro" : "Sign in to upgrade"}
            href={snapshot.isPro ? undefined : CHECKOUT_URL}
            disabled={snapshot.isPro}
            accent
            features={[
              "Cloud agents on isolated Cloud VMs",
              "20 active compute-hours per month, then usage-based",
              "Model gateway with usage and cost analytics",
              "cmux iOS app and email support",
            ]}
          />
        </section>

        <section className="grid gap-3 text-sm sm:grid-cols-3">
          <Metric label="Included compute" value="20 hrs/mo" />
          <Metric label="Default VM" value="4 vCPU / 16 GB" />
          <Metric label="Extra usage" value="metered" />
        </section>
      </div>
    </main>
  );
}

type AppPlanSnapshot = {
  authenticated: boolean;
  planId: string;
  isPro: boolean;
  email: string | null;
};

async function currentPlanSnapshot(): Promise<AppPlanSnapshot> {
  if (!isStackConfigured()) {
    return { authenticated: false, planId: FREE_PLAN_ID, isPro: false, email: null };
  }

  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    return { authenticated: false, planId: FREE_PLAN_ID, isPro: false, email: null };
  }

  const status = await resolveProPlanStatus(user);
  return {
    authenticated: true,
    planId: status.planId,
    isPro: status.isPro,
    email: user.primaryEmail,
  };
}

function CurrentPill({ snapshot }: { snapshot: AppPlanSnapshot }) {
  const label = snapshot.isPro ? "Pro" : "Free";
  const detail = snapshot.authenticated
    ? snapshot.email ?? "Signed in"
    : "Signed out";

  return (
    <div className="flex max-w-full flex-wrap items-center gap-2 self-start text-sm sm:self-auto sm:justify-end">
      <span className="inline-flex items-center gap-2 rounded-full border border-border bg-code-bg px-3 py-1.5">
        <span className="text-muted">Current</span>
        <span className="font-medium">{label}</span>
      </span>
      <span className="min-w-0 max-w-full break-all rounded-full border border-border bg-code-bg px-3 py-1.5 text-muted">
        {detail}
      </span>
    </div>
  );
}

type BillingBannerModel = {
  message: string;
  action?: { href: string; label: string };
};

function appPricingBanner(
  params: Record<string, string | string[] | undefined>,
): BillingBannerModel | null {
  const welcome = firstParam(params.welcome);
  const billing = firstParam(params.billing);

  if (welcome === "success") {
    return { message: "Pro is active. cmux will pick up your plan on the next refresh." };
  }
  if (welcome === "active") {
    return { message: "You already have cmux Pro." };
  }
  if (welcome === "pending") {
    return {
      message: "Stripe is still confirming the subscription.",
      action: { href: "/api/billing/confirm", label: "Check again" },
    };
  }
  if (billing === "error") {
    return { message: "Checkout could not start. Try again in a moment." };
  }
  if (billing === "unavailable") {
    return { message: "Billing is not configured for this environment." };
  }
  return null;
}

function firstParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}

function BillingBanner({ banner }: { banner: BillingBannerModel }) {
  return (
    <div
      role="status"
      className="rounded-lg border border-border bg-code-bg px-4 py-3 text-sm"
    >
      {banner.message}
      {banner.action ? (
        <>
          {" "}
          <a
            href={banner.action.href}
            className="underline underline-offset-2 decoration-border transition-colors hover:decoration-foreground"
          >
            {banner.action.label}
          </a>
        </>
      ) : null}
    </div>
  );
}

function PlanPanel({
  name,
  price,
  period,
  current,
  cta,
  href,
  disabled,
  accent,
  features,
}: {
  name: string;
  price: string;
  period: string;
  current: boolean;
  cta: string;
  href?: string;
  disabled?: boolean;
  accent?: boolean;
  features: string[];
}) {
  return (
    <article
      className={`flex min-h-[25rem] flex-col rounded-lg border p-5 ${
        accent ? "border-border bg-code-bg/80" : "border-border bg-code-bg/60"
      }`}
    >
      <div className="flex items-start justify-between gap-3">
        <h2 className="text-base font-semibold tracking-tight">{name}</h2>
        {current ? (
          <span className="whitespace-nowrap rounded-full border border-border bg-background/30 px-2 py-1 text-xs font-medium">
            Current plan
          </span>
        ) : null}
      </div>
      <div className="mt-4 flex items-baseline gap-1.5">
        <span className="text-4xl font-semibold tracking-tight">{price}</span>
        <span className="text-sm text-muted">{period}</span>
      </div>
      <div className="mt-5">
        {href && !disabled ? (
          <a
            href={href}
            className="inline-flex w-full items-center justify-center rounded-md bg-foreground px-4 py-2.5 text-sm font-medium transition-opacity hover:opacity-85"
            style={{ color: "var(--button-foreground)", textDecoration: "none" }}
          >
            {cta}
          </a>
        ) : (
          <button
            className="inline-flex w-full items-center justify-center rounded-md border border-border px-4 py-2.5 text-sm font-medium text-muted"
            disabled
          >
            {cta}
          </button>
        )}
      </div>
      <ul className="mt-5 flex flex-1 flex-col gap-3 text-sm leading-6">
        {features.map((feature) => (
          <li key={feature} className="flex gap-2.5">
            <CheckIcon />
            <span>{feature}</span>
          </li>
        ))}
      </ul>
    </article>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-border bg-code-bg/55 p-4">
      <p className="text-xs font-medium uppercase tracking-[0.12em] text-muted">
        {label}
      </p>
      <p className="mt-2 text-lg font-semibold tracking-tight">{value}</p>
    </div>
  );
}

function appPricingAppearance(
  params: Record<string, string | string[] | undefined>,
): "light" | "dark" {
  return firstParam(params.appearance) === "dark" ? "dark" : "light";
}

function appPricingStyle(appearance: "light" | "dark"): CSSProperties {
  if (appearance === "dark") {
    return {
      "--foreground": "#ededed",
      "--muted": "#a3a3a3",
      "--border": "rgba(255, 255, 255, 0.18)",
      "--code-bg": "rgba(24, 24, 24, 0.72)",
      "--button-foreground": "#0a0a0a",
    } as CSSProperties;
  }
  return {
    "--foreground": "#171717",
    "--muted": "#5f6368",
    "--border": "rgba(0, 0, 0, 0.14)",
    "--code-bg": "rgba(245, 245, 245, 0.78)",
    "--button-foreground": "#ffffff",
  } as CSSProperties;
}

function CheckIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="mt-1 shrink-0 text-muted"
      aria-hidden="true"
    >
      <path d="M20 6L9 17l-5-5" />
    </svg>
  );
}
