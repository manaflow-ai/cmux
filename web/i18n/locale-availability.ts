import { locales, type Locale } from "./routing";

export const featureWorkflowContentLocales = [
  "en",
  "ja",
] as const satisfies readonly Locale[];

export const featureWorkflowDocPaths = [
  "/docs/vault",
  "/docs/task-manager",
] as const;

export const remoteTmuxDocsLocales = [
  "en",
  "ja",
] as const satisfies readonly Locale[];

export function hasFeatureWorkflowContent(
  locale: string,
): locale is (typeof featureWorkflowContentLocales)[number] {
  return featureWorkflowContentLocales.includes(
    locale as (typeof featureWorkflowContentLocales)[number],
  );
}

export function featureWorkflowDocPathForRequest(
  pathname: string,
): (typeof featureWorkflowDocPaths)[number] | null {
  const normalized =
    pathname.length > 1 && pathname.endsWith("/")
      ? pathname.slice(0, -1)
      : pathname;
  const unprefixed = unprefixLocale(normalized);
  return featureWorkflowDocPaths.includes(
    unprefixed as (typeof featureWorkflowDocPaths)[number],
  )
    ? (unprefixed as (typeof featureWorkflowDocPaths)[number])
    : null;
}

function unprefixLocale(pathname: string): string {
  for (const locale of locales) {
    if (pathname === `/${locale}`) return "/";
    if (pathname.startsWith(`/${locale}/`)) {
      return pathname.slice(locale.length + 1) || "/";
    }
  }
  return pathname;
}
