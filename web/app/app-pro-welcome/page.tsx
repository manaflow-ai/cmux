import { redirect } from "next/navigation";

import enMessages from "../../messages/en.json";
import {
  appPricingAppearance,
  appPricingFirstParam,
  appPricingPageBackground,
  appPricingStyle,
} from "../app-pricing/appearance";

const welcome = enMessages.appProWelcome;

type WelcomeStepKey = "modelGateway" | "aiAccounts" | "iosApp" | "billing";

const STEP_HREFS: Record<WelcomeStepKey, string> = {
  modelGateway: "/dashboard/subrouter",
  aiAccounts: "/dashboard/ai-accounts",
  iosApp: "/dashboard/testflight",
  billing: "/dashboard/billing",
};

const STEP_ORDER: readonly WelcomeStepKey[] = [
  "modelGateway",
  "aiAccounts",
  "iosApp",
  "billing",
];

export const dynamic = "force-dynamic";

export default async function AppProWelcomePage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  // The cmux app only opens this page for a Pro user (the native presenter is
  // gated on the billing plan) and it carries no sensitive data. Web auth is
  // not enforced here yet because the in-app webview does not share the desktop
  // Stack session; once app-browser SSO lands, a getUser + Pro check can gate
  // this like the dashboard. The cmux_app flag keeps it out of the localized
  // route tree.
  if (appPricingFirstParam(params.cmux_app) !== "1") redirect("/dashboard/billing");

  const appearance = appPricingAppearance(params);
  const pageBackground = appPricingPageBackground(params, appearance);

  return (
    <>
      <style>{`
        html, body {
          background: ${pageBackground} !important;
        }
      `}</style>
      <main
        className="min-h-screen w-full px-6 py-10 text-foreground sm:py-12"
        data-app-pro-welcome-appearance={appearance}
        style={appPricingStyle(appearance, pageBackground)}
      >
        <div className="mx-auto w-full max-w-3xl">
          <p className="text-sm font-medium text-muted">{welcome.eyebrow}</p>
          <h1 className="mt-2 text-2xl font-medium tracking-tight">{welcome.title}</h1>
          <p className="mt-3 max-w-2xl text-sm leading-6 text-muted">{welcome.body}</p>

          <div className="mt-8 grid gap-4 sm:grid-cols-2">
            {STEP_ORDER.map((key) => {
              const step = welcome.steps[key];
              return (
                <article
                  key={key}
                  className="flex min-h-40 flex-col justify-between border border-border p-5"
                >
                  <div>
                    <h2 className="text-base font-medium">{step.title}</h2>
                    <p className="mt-2 text-sm leading-6 text-muted">{step.body}</p>
                  </div>
                  <a
                    className="mt-4 inline-flex w-fit px-3 py-2 text-sm font-medium"
                    style={{
                      backgroundColor: "var(--foreground)",
                      color: "var(--button-foreground)",
                    }}
                    href={STEP_HREFS[key]}
                  >
                    {step.action}
                  </a>
                </article>
              );
            })}
          </div>

          <div className="mt-8 border-t border-border pt-6">
            <a
              className="inline-flex border border-border px-4 py-2 text-sm font-medium text-foreground"
              href="/dashboard"
            >
              {welcome.done}
            </a>
          </div>
        </div>
      </main>
    </>
  );
}
