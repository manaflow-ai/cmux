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

// These routes currently ship page copy and metadata only in English and Japanese.
export const fallbackContentLocales = [
  "en",
  "ja",
] as const satisfies readonly Locale[];

export const fallbackContentPaths = [
  "/pricing",
  "/docs/agent-integrations/oh-my-pi",
] as const;

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

export function hasFallbackContent(
  locale: string,
): locale is (typeof fallbackContentLocales)[number] {
  return fallbackContentLocales.includes(
    locale as (typeof fallbackContentLocales)[number],
  );
}

export function fallbackContentRequestForPathname(
  pathname: string,
): {
  path: (typeof fallbackContentPaths)[number];
  locale: Locale | null;
} | null {
  const { locale, path } = unprefixLocale(pathname);
  if (
    fallbackContentPaths.includes(
      path as (typeof fallbackContentPaths)[number],
    )
  ) {
    return {
      path: path as (typeof fallbackContentPaths)[number],
      locale,
    };
  }
  return null;
}

function unprefixLocale(pathname: string): { locale: Locale | null; path: string } {
  let decoded: string;
  try {
    decoded = decodeURI(pathname)
      .replace(/\\/gu, "%5C")
      .replace(/[\t\n\r]/gu, "")
      .replace(/\/+/gu, "/");
  } catch {
    return { locale: null, path: pathname };
  }
  const normalized =
    decoded.length > 1 && decoded.endsWith("/")
      ? decoded.slice(0, -1)
      : decoded;
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
