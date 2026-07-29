import { redirect } from "next/navigation";
import { getLocale } from "next-intl/server";

import { loadMessages } from "../../i18n/messages";
import { routing, type Locale } from "../../i18n/routing";
import {
  appPricingAppearance,
  appPricingFirstParam,
  appPricingPageBackground,
  appPricingStyle,
} from "../app-pricing/appearance";

const APP_BROWSER_QUERY = "cmux_open_in_browser=split-right";

type WelcomeStepKey = "iosApp" | "billing";

type AppProWelcomeMessages = {
  eyebrow: string;
  title: string;
  body: string;
  done: string;
  steps: Record<WelcomeStepKey, {
    title: string;
    body: string;
    action: string;
  }>;
};

const STEP_HREFS: Record<WelcomeStepKey, string> = {
  iosApp: `/dashboard/testflight?${APP_BROWSER_QUERY}`,
  billing: `/dashboard/billing?${APP_BROWSER_QUERY}`,
};

const STEP_ORDER: readonly WelcomeStepKey[] = [
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
  const catalog = await loadMessages(supportedLocale(await getLocale())) as {
    appProWelcome: AppProWelcomeMessages;
  };
  const welcome = catalog.appProWelcome;

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
                    <p className="mt-2 text-sm leading-5 text-muted">{step.body}</p>
                  </div>
                  <a
                    className="mt-4 inline-flex w-fit px-3 py-2 text-sm font-medium"
                    style={{
                      backgroundColor: "var(--foreground)",
                      color: "var(--button-foreground)",
                    }}
                    href={STEP_HREFS[key]}
                    rel="noopener"
                    target="_blank"
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
              href={`/dashboard?${APP_BROWSER_QUERY}`}
              rel="noopener"
              target="_blank"
            >
              {welcome.done}
            </a>
          </div>
        </div>
      </main>
    </>
  );
}

function supportedLocale(locale: string): Locale {
  return routing.locales.find((candidate) => candidate === locale)
    ?? routing.defaultLocale;
}
