import { locales, type Locale } from "./routing";

// Every shipped message catalog contains every English source message. Keep
// route discovery, navigation, metadata, and agent-readable variants aligned
// with the complete locale list.
export const translatedContentLocales = locales;
export const featureWorkflowContentLocales = translatedContentLocales;

export const featureWorkflowDocPaths = [
  "/docs/vault",
  "/docs/task-manager",
] as const;

export const remoteTmuxDocsLocales = translatedContentLocales;
export const fallbackContentLocales = translatedContentLocales;
export const englishFallbackContentLocales = translatedContentLocales;
const extendedAgentIntegrationContentLocales = translatedContentLocales;

// Keep route metadata and internal links on one source of truth.
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
