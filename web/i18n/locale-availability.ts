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

// Routes in this registry intentionally expose only their authored locales.
export const fallbackContentLocales = [
  "en",
  "ja",
] as const satisfies readonly Locale[];

export const englishFallbackContentLocales = [
  "en",
] as const satisfies readonly Locale[];

const fallbackContentRoutes = [
  { path: "/pricing", locales: fallbackContentLocales },
  {
    path: "/docs/agent-integrations/oh-my-pi",
    locales: fallbackContentLocales,
  },
  { path: "/blog/cmux-ssh", locales: fallbackContentLocales },
  {
    path: "/blog/cmux-claude-teams",
    locales: englishFallbackContentLocales,
  },
  { path: "/blog/cmux-omo", locales: englishFallbackContentLocales },
  { path: "/blog/gpl", locales: englishFallbackContentLocales },
] as const;

export const fallbackContentPaths = fallbackContentRoutes.map(
  ({ path }) => path,
);

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
  availableLocales: readonly Locale[] = fallbackContentLocales,
): boolean {
  return availableLocales.includes(
    locale as Locale,
  );
}

export function fallbackContentRequestForPathname(
  pathname: string,
): {
  path: (typeof fallbackContentRoutes)[number]["path"];
  locale: Locale | null;
  locales: readonly Locale[];
} | null {
  const { locale, path } = unprefixLocale(pathname);
  const route = fallbackContentRoutes.find((candidate) => candidate.path === path);
  if (route) {
    return {
      path: route.path,
      locale,
      locales: route.locales,
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
