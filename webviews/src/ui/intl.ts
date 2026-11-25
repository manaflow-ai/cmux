// One Intl formatter per (kind, locales, options), shared by every caller.
//
// Constructing an Intl object resolves the locale, loads its ICU data and compiles a pattern; that costs
// far more than the format() call it is made for (Allegro Tech, "Using ESLint to improve your app's
// performance": https://blog.allegro.tech/2020/08/using-eslint.html). A row that built one per render
// paid it once per row per render. Call `intl.NumberFormat(locale, options)` where you would write
// `new Intl.NumberFormat(locale, options)`; the perf-footguns lint rule `cmux-perf/no-intl-construct`
// points here.
//
// A formatter made without an explicit locale or `timeZone` keeps the defaults it was made with, so the
// whole cache is dropped once a minute: a zone or language change shows within a minute, and the cache
// stays small. `intl.DateTimeFormat().resolvedOptions()` reads the current defaults the same way.

const EPOCH_MS = 60_000;
const LIMIT = 512;

let cache = new Map<string, unknown>();
let epoch = 0;

function cached<T>(kind: string, locales: unknown, options: unknown, make: () => T): T {
  const now = Date.now();
  if (now - epoch >= EPOCH_MS || cache.size >= LIMIT) {
    cache = new Map();
    epoch = now;
  }
  const key = `${kind}\u0000${JSON.stringify(locales ?? null)}\u0000${JSON.stringify(options ?? null)}`;
  let found = cache.get(key) as T | undefined;
  if (found === undefined) {
    found = make();
    cache.set(key, found);
  }
  return found;
}

type Locales = string | readonly string[] | undefined;

export const intl = {
  NumberFormat: (locales?: Locales, options?: Intl.NumberFormatOptions): Intl.NumberFormat =>
    cached("NumberFormat", locales, options, () => new Intl.NumberFormat(locales as string[], options)),
  DateTimeFormat: (locales?: Locales, options?: Intl.DateTimeFormatOptions): Intl.DateTimeFormat =>
    cached("DateTimeFormat", locales, options, () => new Intl.DateTimeFormat(locales as string[], options)),
  RelativeTimeFormat: (locales?: Locales, options?: Intl.RelativeTimeFormatOptions): Intl.RelativeTimeFormat =>
    cached("RelativeTimeFormat", locales, options, () => new Intl.RelativeTimeFormat(locales as string[], options)),
  ListFormat: (locales?: Locales, options?: Intl.ListFormatOptions): Intl.ListFormat =>
    cached("ListFormat", locales, options, () => new Intl.ListFormat(locales as string[], options)),
  PluralRules: (locales?: Locales, options?: Intl.PluralRulesOptions): Intl.PluralRules =>
    cached("PluralRules", locales, options, () => new Intl.PluralRules(locales as string[], options)),
  Collator: (locales?: Locales, options?: Intl.CollatorOptions): Intl.Collator =>
    cached("Collator", locales, options, () => new Intl.Collator(locales as string[], options)),
  Segmenter: (locales?: Locales, options?: Intl.SegmenterOptions): Intl.Segmenter =>
    cached("Segmenter", locales, options, () => new Intl.Segmenter(locales as string[], options)),
  DisplayNames: (locales: Locales, options: Intl.DisplayNamesOptions): Intl.DisplayNames =>
    cached("DisplayNames", locales, options, () => new Intl.DisplayNames(locales as string[], options)),
};

/** Tests only: start from an empty cache. */
export function resetIntlCacheForTests(): void {
  cache = new Map();
  epoch = 0;
}
