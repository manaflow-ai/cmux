"use client";

import { useRef, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { useRouter } from "../../../i18n/navigation";
import {
  nextDocsSearchIndex,
  normalizeDocsSearchResult,
  type DocsSearchResult,
  type PagefindResultData,
} from "./docs-search-utils";
import { DocsLink } from "./docs-link";
import { useDocsChannel } from "./docs-channel-context";
import {
  docsChannelUrl,
  docsPathAvailableInChannel,
} from "@/app/lib/docs-channel";

type PagefindModule = {
  init: () => Promise<void> | void;
  options: (options: {
    highlightParam?: string;
    ranking?: {
      pageLength?: number;
      termFrequency?: number;
      metaWeights?: Record<string, number>;
    };
  }) => Promise<void> | void;
  debouncedSearch: (
    term: string,
    options?: {
      filters?: Record<string, string>;
    },
    debounceTimeoutMs?: number,
  ) => Promise<null | { results: Array<{ data: () => Promise<PagefindResultData> }> }>;
};

let pagefindPromise: Promise<PagefindModule> | null = null;
let pagefindConfigurePromise: Promise<PagefindModule> | null = null;

function importPagefind(channel: "release" | "nightly") {
  const pagefindBundlePath = `/_docs-search/${channel}/pagefind.js`;
  return import(
    /* webpackIgnore: true */
    pagefindBundlePath
  ) as Promise<PagefindModule>;
}

async function loadPagefind(channel: "release" | "nightly") {
  if (!pagefindPromise) {
    pagefindPromise = importPagefind(channel).catch((error) => {
      pagefindPromise = null;
      throw error;
    });
  }

  if (!pagefindConfigurePromise) {
    pagefindConfigurePromise = pagefindPromise
      .then(async (pagefind) => {
        await pagefind.options({
          highlightParam: "highlight",
          ranking: {
            pageLength: 0.6,
            termFrequency: 0.8,
            metaWeights: {
              title: 8,
              section: 2,
            },
          },
        });
        await pagefind.init();
        return pagefind;
      })
      .catch((error) => {
        pagefindPromise = null;
        pagefindConfigurePromise = null;
        throw error;
      });
  }

  return pagefindConfigurePromise;
}

type SearchStatus = "idle" | "loading" | "ready" | "error";

export function DocsSearch({ onNavigate }: { onNavigate?: () => void }) {
  const t = useTranslations("docs.search");
  const locale = useLocale();
  const router = useRouter();
  const channel = useDocsChannel();
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<SearchStatus>("idle");
  const [results, setResults] = useState<DocsSearchResult[]>([]);
  const [activeIndex, setActiveIndex] = useState(-1);
  const requestIdRef = useRef(0);

  async function search(nextQuery: string) {
    setQuery(nextQuery);
    const requestId = requestIdRef.current + 1;
    requestIdRef.current = requestId;
    setActiveIndex(-1);

    const trimmedQuery = nextQuery.trim();
    if (trimmedQuery.length < 2) {
      setStatus("idle");
      setResults([]);
      return;
    }

    setStatus("loading");

    try {
      const pagefind = await loadPagefind(channel);
      const searchResult = await pagefind.debouncedSearch(
        trimmedQuery,
        { filters: { locale } },
        180,
      );
      if (requestIdRef.current !== requestId || searchResult === null) return;

      const pageData = await Promise.all(
        searchResult.results.slice(0, 12).map((result) => result.data()),
      );
      if (requestIdRef.current !== requestId) return;

      const normalizedResults = pageData
        .map(normalizeDocsSearchResult)
        .filter((result) => docsPathAvailableInChannel(channel, result.href))
        .slice(0, 8);
      setResults(normalizedResults);
      setActiveIndex(normalizedResults.length ? 0 : -1);
      setStatus("ready");
    } catch {
      if (requestIdRef.current !== requestId) return;
      setStatus("error");
      setResults([]);
    }
  }

  function clearAndNavigate() {
    requestIdRef.current += 1;
    setQuery("");
    setResults([]);
    setStatus("idle");
    setActiveIndex(-1);
    onNavigate?.();
  }

  function preloadPagefind() {
    void loadPagefind(channel).catch(() => {});
  }

  function handleKeyDown(event: React.KeyboardEvent<HTMLInputElement>) {
    if (event.nativeEvent.isComposing) return;

    const currentQuery = event.currentTarget.value;
    const isUnsyncedQuery = currentQuery !== query;

    if (event.key === "Escape" && (query || currentQuery)) {
      event.preventDefault();
      clearAndNavigate();
      return;
    }

    if (isUnsyncedQuery) {
      void search(currentQuery);
    }

    if (!results.length) return;

    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActiveIndex((index) =>
        nextDocsSearchIndex({
          currentIndex: index,
          direction: "next",
          resultCount: results.length,
        }),
      );
      return;
    }

    if (event.key === "ArrowUp") {
      event.preventDefault();
      setActiveIndex((index) =>
        nextDocsSearchIndex({
          currentIndex: index,
          direction: "previous",
          resultCount: results.length,
        }),
      );
      return;
    }

    if (event.key === "Enter" && activeIndex >= 0) {
      event.preventDefault();
      const result = results[activeIndex];
      if (!result) return;
      router.push(docsChannelUrl(channel, result.href));
      clearAndNavigate();
    }
  }

  const showResults =
    query.trim().length >= 2 && (status !== "loading" || results.length > 0);
  const statusMessage =
    status === "error"
      ? t("error")
      : status === "ready" && results.length === 0
        ? t("noResults")
        : null;

  return (
    <div className="pb-4" data-pagefind-ignore="all">
      <div className="relative">
        <div className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-muted/40">
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <circle cx="11" cy="11" r="8" />
            <path d="M21 21l-4.3-4.3" />
          </svg>
        </div>
        <input
          value={query}
          onChange={(event) => void search(event.target.value)}
          onFocus={preloadPagefind}
          onKeyDown={handleKeyDown}
          placeholder={t("placeholder")}
          role="combobox"
          aria-label={t("label")}
          aria-controls="docs-search-results"
          aria-expanded={showResults}
          aria-autocomplete="list"
          aria-activedescendant={
            activeIndex >= 0 ? `docs-search-result-${activeIndex}` : undefined
          }
          className="w-full rounded-md border border-transparent bg-code-bg/60 py-1.5 pl-8 pr-3 text-[13px] transition-colors placeholder:text-muted/40 hover:bg-code-bg focus:border-border focus:bg-code-bg focus:outline-none"
        />
      </div>

      {showResults && (
        <div
          id="docs-search-results"
          role="listbox"
          aria-label={t("resultsLabel")}
          className="pt-2"
          aria-live="polite"
        >
          {statusMessage ? (
            <div className="rounded-md bg-code-bg/35 px-2 py-2 text-[12px] text-muted/60">
              {statusMessage}
            </div>
          ) : (
            <div className="space-y-1 rounded-md bg-code-bg/35 p-1">
              <div className="px-1 pb-1 text-[11px] text-muted/50">
                {t("resultsCount", { count: results.length })}
              </div>
              {results.map((result, index) => (
                <DocsLink
                  id={`docs-search-result-${index}`}
                  key={`${result.href}-${index}`}
                  href={result.href}
                  role="option"
                  aria-selected={index === activeIndex}
                  onClick={clearAndNavigate}
                  onMouseEnter={() => setActiveIndex(index)}
                  className={`block rounded-md px-2 py-2 transition-colors ${
                    index === activeIndex
                      ? "bg-background/80 text-foreground"
                      : "text-muted hover:bg-background/60 hover:text-foreground"
                  }`}
                >
                  <div className="truncate text-[13px] font-medium">
                    {result.title}
                  </div>
                  {result.excerptHtml && (
                    <div
                      className="docs-search-excerpt mt-1 line-clamp-2 text-[12px] leading-5 text-muted/80"
                      dangerouslySetInnerHTML={{ __html: result.excerptHtml }}
                    />
                  )}
                  <div className="mt-1 truncate text-[11px] text-muted/45">
                    {result.href.replace(/^\/[a-z]{2}(?:-[A-Z]{2})?\//, "/")}
                  </div>
                </DocsLink>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
