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
  return featureWorkflowDocRequestForPathname(pathname)?.path ?? null;
}

export function featureWorkflowDocRequestForPathname(
  pathname: string,
): {
  path: (typeof featureWorkflowDocPaths)[number];
  locale: Locale | null;
} | null {
  const { locale, path } = unprefixLocale(pathname);
  if (
    featureWorkflowDocPaths.includes(
      path as (typeof featureWorkflowDocPaths)[number],
    )
  ) {
    return {
      path: path as (typeof featureWorkflowDocPaths)[number],
      locale,
    };
  }
  return null;
}

function unprefixLocale(pathname: string): { locale: Locale | null; path: string } {
  const normalized =
    pathname.length > 1 && pathname.endsWith("/")
      ? pathname.slice(0, -1)
      : pathname;
  for (const locale of locales) {
    if (normalized === `/${locale}`) {
      return { locale, path: "/" };
    }
    if (normalized.startsWith(`/${locale}/`)) {
      return {
        locale,
        path: normalized.slice(locale.length + 1) || "/",
      };
    }
  }
  return { locale: null, path: normalized };
}
