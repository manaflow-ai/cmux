import { locales } from "../../../i18n/routing";

export type PagefindSubResult = {
  title?: string;
  url?: string;
  excerpt?: string;
  plain_excerpt?: string;
  weighted_locations?: Array<{
    balanced_score?: number;
    weight?: number;
  }>;
};

export type PagefindResultData = {
  url: string;
  excerpt?: string;
  plain_excerpt?: string;
  meta?: {
    title?: string;
    section?: string;
  };
  sub_results?: PagefindSubResult[];
};

export type DocsSearchResult = {
  href: string;
  title: string;
  section?: string;
  excerptHtml: string;
  plainExcerpt: string;
};

export function normalizePagefindUrl(url: string): string {
  let pathname = url;
  let hash = "";

  try {
    const parsed = new URL(url, "https://cmux.com");
    pathname = parsed.pathname;
    hash = parsed.hash;
  } catch {
    const hashIndex = pathname.indexOf("#");
    if (hashIndex >= 0) {
      hash = pathname.slice(hashIndex);
      pathname = pathname.slice(0, hashIndex);
    }
  }

  pathname = pathname.replace(/\/index\.html$/, "");
  if (pathname.length > 1) {
    pathname = pathname.replace(/\/$/, "");
  }

  return `${pathname || "/"}${hash}`;
}

const localePathPrefixes = new Set<string>(locales);

function stripLocalePrefix(url: string): string {
  const hashIndex = url.indexOf("#");
  const pathname = hashIndex >= 0 ? url.slice(0, hashIndex) : url;
  const hash = hashIndex >= 0 ? url.slice(hashIndex) : "";
  const parts = pathname.split("/");

  if (parts.length > 2 && localePathPrefixes.has(parts[1] ?? "")) {
    return `/${parts.slice(2).join("/")}${hash}`;
  }

  return url;
}

export function normalizeDocsSearchResult(
  data: PagefindResultData,
): DocsSearchResult {
  const subResult = bestSubResult(data.sub_results);
  const title = subResult?.title || data.meta?.title || "Docs";
  const excerptHtml = subResult?.excerpt || data.excerpt || "";
  const plainExcerpt = subResult?.plain_excerpt || data.plain_excerpt || "";

  return {
    href: stripLocalePrefix(normalizePagefindUrl(subResult?.url || data.url)),
    title,
    section: data.meta?.section,
    excerptHtml,
    plainExcerpt,
  };
}

function bestSubResult(subResults?: PagefindSubResult[]) {
  const candidates = subResults?.filter((item) => item.excerpt || item.url) ?? [];
  if (!candidates.length) return undefined;

  const best = candidates.reduce((best, candidate) => {
    const bestScore = subResultScore(best);
    const candidateScore = subResultScore(candidate);
    if (candidateScore > bestScore) return candidate;
    return best;
  });
  if (!isTitleSubResult(best)) return best;

  const bestSection = candidates
    .filter((candidate) => !isTitleSubResult(candidate))
    .reduce<PagefindSubResult | undefined>((section, candidate) => {
      if (!section || subResultScore(candidate) > subResultScore(section)) {
        return candidate;
      }
      return section;
    }, undefined);

  if (bestSection && subResultScore(bestSection) >= subResultScore(best) * 0.65) {
    return bestSection;
  }

  return best;
}

function subResultScore(result: PagefindSubResult) {
  return (
    result.weighted_locations?.reduce(
      (score, location) =>
        score + (location.balanced_score ?? location.weight ?? 0),
      0,
    ) ?? 0
  );
}

function isTitleSubResult(result: PagefindSubResult) {
  const hash = resultHash(result.url ?? "");
  return !hash || hash === "#title";
}

function resultHash(url: string) {
  try {
    return new URL(url, "https://cmux.com").hash;
  } catch {
    const hashIndex = url.indexOf("#");
    return hashIndex >= 0 ? url.slice(hashIndex) : "";
  }
}

export function nextDocsSearchIndex({
  currentIndex,
  direction,
  resultCount,
}: {
  currentIndex: number;
  direction: "next" | "previous";
  resultCount: number;
}): number {
  if (resultCount <= 0) return -1;
  if (direction === "next") {
    return (Math.max(currentIndex, -1) + 1) % resultCount;
  }
  return (currentIndex <= 0 ? resultCount : currentIndex) - 1;
}
