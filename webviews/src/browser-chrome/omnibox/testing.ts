// Test support: a resolver with the address rules the ported tests need, and input helpers. The
// real resolver (BrowserURLResolver, intranet probe) stays native; this one covers explicit
// http(s), loopback over http, and dotted hosts or hosts with a port over https.
import { fixHostTypo, HostTypoMemory } from "./host-typo-fixup";
import { reduce } from "./reducer";
import { SEARCH_ENGINES, searchEngineKeywords, searchURL } from "./search-engine";
import type { OmnibarState } from "./state";
import type {
  BrowserSuggestion,
  OmnibarEffect,
  OmnibarInput,
  OmnibarKeyword,
  OmniboxDestination,
  OmniboxResolver,
  SearchEngine,
} from "./types";
import { parseURL } from "./url-display";

export function testURL(input: string): string | null {
  const text = input.trim();
  if (!text || /\s/.test(text)) return null;
  const explicit = /^([A-Za-z][A-Za-z0-9+.-]*):\/\//.exec(text);
  if (explicit) {
    const scheme = explicit[1].toLowerCase();
    if (scheme !== "http" && scheme !== "https") return null;
    return parseURL(text)?.host ? text : null;
  }
  const end = text.search(/[/?#]/);
  const authority = end < 0 ? text : text.slice(0, end);
  const match = /^([^:@]+)(?::(\d+))?$/.exec(authority);
  if (!match) return null;
  const host = match[1].toLowerCase();
  if (host === "localhost" || /^127\.\d+\.\d+\.\d+$/.test(host)) return `http://${text}`;
  if (match[2] || /\.[a-z]{2,}$/.test(host) || /^\d+\.\d+\.\d+\.\d+$/.test(host)) return `https://${text}`;
  return null;
}

export function testResolver(
  options: { keywords?: OmnibarKeyword[]; searchEngine?: SearchEngine; memory?: HostTypoMemory } = {},
): OmniboxResolver {
  const engine = options.searchEngine ?? SEARCH_ENGINES.google;
  const memory = options.memory ?? new HostTypoMemory();
  return {
    keywords: options.keywords ?? [],
    searchEngine: engine,
    url: testURL,
    destination(input: string): OmniboxDestination | null {
      const trimmed = input.trim();
      if (trimmed.startsWith("?")) {
        const query = trimmed.slice(1).trim();
        const url = query ? searchURL(engine, query) : null;
        return url ? { kind: "search", query, url } : null;
      }
      const url = testURL(input);
      if (url) return { kind: "url", url };
      const search = searchURL(engine, trimmed);
      return search ? { kind: "search", query: trimmed, url: search } : null;
    },
    typoFixedURL(input: string) {
      const fix = fixHostTypo(input);
      if (!fix || !memory.allowsFix(fix.typedHost)) return null;
      const url = testURL(fix.text);
      return url ? { url, typedHost: fix.typedHost } : null;
    },
  };
}

/** The resolver with the search engine keywords (tab to search). */
export const engineResolver = (): OmniboxResolver =>
  testResolver({ keywords: searchEngineKeywords(SEARCH_ENGINES.google) });

export function run(
  state: OmnibarState,
  inputs: readonly OmnibarInput[],
  resolver: OmniboxResolver = testResolver(),
): { state: OmnibarState; effects: OmnibarEffect[]; handled: boolean } {
  let current = state;
  const effects: OmnibarEffect[] = [];
  let handled = true;
  for (const input of inputs) {
    const step = reduce(current, input, resolver);
    current = step.state;
    effects.push(...step.effects);
    handled = step.handled;
  }
  return { state: current, effects, handled };
}

/** Keys typed one by one after `start`, with keyboard focus first unless `focus` is false. */
export function typed(text: string, start = "", focus = true): OmnibarInput[] {
  const inputs: OmnibarInput[] = focus ? [{ type: "focusGained", source: "keyboard" }] : [];
  let current = start;
  for (const character of Array.from(text)) {
    current += character;
    inputs.push({
      type: "fieldChanged",
      field: { text: current, selection: { location: current.length, length: 0 } },
      kind: "insert",
    });
  }
  return inputs;
}

export const key = (k: Extract<OmnibarInput, { type: "key" }>["key"]): OmnibarInput => ({ type: "key", key: k });

export const enterKey: OmnibarInput = { type: "key", key: { kind: "enter", disposition: "currentTab" } };

export function selection(text: string, location: number, length = 0): OmnibarInput {
  return { type: "fieldChanged", field: { text, selection: { location, length } }, kind: null };
}

export function commits(effects: readonly OmnibarEffect[]): string[] {
  return effects.flatMap((effect) =>
    effect.type === "ended" && effect.reason.kind === "commit" ? [effect.reason.url] : [],
  );
}

export function row(
  kind: BrowserSuggestion["kind"],
  url: string,
  extra: Partial<BrowserSuggestion> = {},
): BrowserSuggestion {
  return { kind, title: extra.title ?? url, detail: "", url, score: 1, ...extra };
}

/** The generation of the last query effect. */
export function lastGeneration(effects: readonly OmnibarEffect[]): number {
  for (let index = effects.length - 1; index >= 0; index--) {
    const effect = effects[index];
    if (effect.type === "query" || effect.type === "keywordInput") return effect.generation;
  }
  return -1;
}
