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

const extendedAgentIntegrationContentLocales = [
  "en",
  "ja",
  "uk",
] as const satisfies readonly Locale[];

// Routes in this registry render fallback messages outside these authored
// locales. Keep redirects, sitemap entries, page metadata, and internal links
// on this shared source of truth so crawlers never receive duplicate locale
// URLs with self-referencing canonicals.
export const authoredContentLocalesByPath = {
  "/ios": fallbackContentLocales,
  "/pricing": fallbackContentLocales,
  "/enterprise": fallbackContentLocales,
  "/docs/agent-integrations/claude-code-teams":
    extendedAgentIntegrationContentLocales,
  "/docs/agent-integrations/oh-my-opencode":
    extendedAgentIntegrationContentLocales,
  "/docs/agent-integrations/oh-my-codex": fallbackContentLocales,
  "/docs/agent-integrations/oh-my-pi": fallbackContentLocales,
  "/docs/agent-integrations/oh-my-claudecode": fallbackContentLocales,
  "/blog/claude-code-best-worktree-manager": fallbackContentLocales,
  "/blog/cmux-ssh": fallbackContentLocales,
  "/blog/cmux-claude-teams": englishFallbackContentLocales,
  "/blog/cmux-omo": englishFallbackContentLocales,
  "/blog/gpl": englishFallbackContentLocales,
} as const satisfies Record<string, readonly Locale[]>;

type AuthoredContentPath = keyof typeof authoredContentLocalesByPath;

export const fallbackContentPaths = Object.keys(
  authoredContentLocalesByPath,
) as AuthoredContentPath[];

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
  path: AuthoredContentPath;
  locale: Locale | null;
  locales: readonly Locale[];
} | null {
  const { locale, path } = unprefixLocale(pathname);
  const availableLocales =
    authoredContentLocalesByPath[path as AuthoredContentPath];
  if (availableLocales) {
    return {
      path: path as AuthoredContentPath,
      locale,
      locales: availableLocales,
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
