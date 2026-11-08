// URL resolution and search fallback (OmniboxResolver in BrowserSearchEngine.swift): the
// synchronous resolver the reducer calls, built from data the host pushes in.
import { fixHostTypo, HostTypoMemory } from "../host-typo-fixup";
import { SEARCH_ENGINES, searchURL } from "../search-engine";
import { trimSpaces } from "../text";
import type { OmnibarKeyword, OmniboxDestination, OmniboxResolver, SearchEngine } from "../types";
import { urlHost, urlScheme } from "../url-display";
import { intranetCandidate, IntranetHostMemory } from "./intranet";
import { isTopLevelDomain } from "./top-level-domains.generated";
import { createURLResolver, isLoopback, type URLResolverConfig } from "./url-resolver";
import { trimWhitespace } from "./url-text";

export interface OmniboxResolverConfig extends URLResolverConfig {
  /** Google when absent. */
  searchEngine?: SearchEngine;
  /** Extension keywords of the tab and the search engine keywords. */
  keywords?: readonly OmnibarKeyword[];
  /** Typed hosts already fixed once; share one per profile. */
  hostTypoMemory?: HostTypoMemory;
  /** Bare words that resolved as intranet hosts; share one per profile. */
  intranetHosts?: IntranetHostMemory;
}

export interface BrowserOmniboxResolver extends OmniboxResolver {
  readonly hostTypoMemory: HostTypoMemory;
  readonly intranetHosts: IntranetHostMemory;
  /** `typoFixedURL` for a commit: the fix is recorded, so the same typed host loads as typed next time. */
  commitTypoFix(text: string): string | null;
  /**
   * The web search a typed intranet address also offers (Chrome lists "go/gday - Google Search"
   * under `http://go/gday`); null for any other input.
   */
  intranetSearchAlternative(text: string): { query: string; url: string } | null;
}

export function createOmniboxResolver(config: OmniboxResolverConfig = {}): BrowserOmniboxResolver {
  const searchEngine = config.searchEngine ?? SEARCH_ENGINES.google;
  const hostTypoMemory = config.hostTypoMemory ?? new HostTypoMemory();
  const intranetHosts = config.intranetHosts ?? new IntranetHostMemory();
  const url = createURLResolver(config);

  function search(query: string): OmniboxDestination | null {
    const target = searchURL(searchEngine, query);
    return target ? { kind: "search", query, url: target } : null;
  }

  /** Where `text` goes: a URL, else a search. A leading `?` forces a search for the rest. */
  function destination(text: string): OmniboxDestination | null {
    const trimmed = trimWhitespace(text);
    if (trimmed.startsWith("?")) {
      const query = trimSpaces(trimmed.slice(1));
      return query ? search(query) : null;
    }
    const target = url(text);
    if (target) return { kind: "url", url: target };
    const label = intranetCandidate(trimmed);
    if (label && intranetHosts.isIntranetHost(label)) return { kind: "url", url: `http://${label}/` };
    return search(trimmed);
  }

  function typoFixedURL(text: string): { url: string; typedHost: string } | null {
    const fix = fixHostTypo(text, isTopLevelDomain);
    if (!fix || !hostTypoMemory.allowsFix(fix.typedHost)) return null;
    const fixed = url(fix.text);
    return fixed ? { url: fixed, typedHost: fix.typedHost } : null;
  }

  return {
    keywords: config.keywords ?? [],
    searchEngine,
    hostTypoMemory,
    intranetHosts,
    url,
    destination,
    typoFixedURL,
    commitTypoFix(text) {
      const fixed = typoFixedURL(text);
      if (!fixed) return null;
      hostTypoMemory.recordFix(fixed.typedHost);
      return fixed.url;
    },
    intranetSearchAlternative(text) {
      const trimmed = trimWhitespace(text);
      if (trimmed.startsWith("?") || trimmed.includes("://")) return null;
      const target = destination(trimmed);
      if (target?.kind !== "url" || urlScheme(target.url) !== "http") return null;
      const host = urlHost(target.url);
      if (!host || host.includes(".") || host.includes(":") || isLoopback(host)) return null;
      const alternative = searchURL(searchEngine, trimmed);
      return alternative ? { query: trimmed, url: alternative } : null;
    },
  };
}
