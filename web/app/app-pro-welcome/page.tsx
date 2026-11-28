import { redirect } from "next/navigation";
import { getLocale } from "./locale";

import { loadMessages } from "../../i18n/messages";
import { routing, type Locale } from "../../i18n/routing";
import {
  appPricingFirstParam,
  appPricingTheme,
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

const STEP_PATHS: Record<WelcomeStepKey, string> = {
  iosApp: "/dashboard/testflight",
  billing: "/dashboard/billing",
};

const STEP_ORDER: readonly WelcomeStepKey[] = [
  "iosApp",
  "billing",
];


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

  const theme = appPricingTheme(params);
  const locale = supportedLocale(await getLocale());
  const catalog = await loadMessages(locale) as {
    appProWelcome: AppProWelcomeMessages;
  };
  const welcome = catalog.appProWelcome;

  return (
    <>
      <style>{`
        html, body {
          background: ${theme.background} !important;
        }
      `}</style>
      <main
        className="min-h-screen w-full px-6 py-10 text-foreground sm:py-12"
        data-cmux-app-theme="true"
        data-cmux-app-theme-appearance={theme.appearance}
        data-app-pro-welcome-appearance={theme.appearance}
        style={appPricingStyle(theme)}
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
                    href={localizedDashboardHref(locale, STEP_PATHS[key])}
                  >
                    {step.action}
                  </a>
                </article>
              );
            })}
          </div>

          <div className="mt-8 border-t border-border pt-6">
            {/* Keep app-web navigation as a full document load in WKWebView. */}
            {/* eslint-disable-next-line @next/next/no-html-link-for-pages */}
            <a
              className="inline-flex border border-border px-4 py-2 text-sm font-medium text-foreground"
              href={localizedDashboardHref(locale, "/dashboard")}
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

function localizedDashboardHref(locale: Locale, path: string): string {
  const prefix = locale === routing.defaultLocale ? "" : `/${locale}`;
  return `${prefix}${path}?${APP_BROWSER_QUERY}`;
}
