// Page strings come from xcstrings tables (scripts/pages/gen-strings.mjs writes
// `<page>/generated/strings.json`); no string lives only in TypeScript. The page picks the app's
// language from `navigator.languages`, which WebKit sets from the app's preferred localizations.

export type StringTable = Record<string, Record<string, string>>;

const RTL_LANGUAGES = new Set(["ar", "fa", "he", "ur", "ps", "sd", "ug", "yi"]);

export function isRtlLanguage(language: string): boolean {
  return RTL_LANGUAGES.has(language.split(/[-_]/)[0].toLowerCase());
}

/** Apple localization code for a BCP 47 language tag, among the codes the table has. */
export function resolveLanguage(tags: readonly string[], available: readonly string[]): string {
  const has = new Set(available);
  for (const raw of tags) {
    const tag = raw.replace(/_/g, "-");
    if (has.has(tag)) return tag;
    const [base, ...rest] = tag.split("-");
    const lower = base.toLowerCase();
    if (lower === "zh") {
      const traditional = rest.some((part) => /^(hant|tw|hk|mo)$/i.test(part));
      const code = traditional ? "zh-Hant" : "zh-Hans";
      if (has.has(code)) return code;
      continue;
    }
    if (lower === "pt" && has.has("pt-BR")) return "pt-BR";
    if ((lower === "no" || lower === "nn") && has.has("nb")) return "nb";
    if (has.has(lower)) return lower;
  }
  return "en";
}

export interface Strings {
  readonly language: string;
  t(key: string): string;
  /** `t(key)` with printf-style object placeholders (`%@`, `%1$@`) replaced by `args`. A plural
   * string (`key#<category>` in the table, gen-strings.mjs) takes the form the language's plural
   * rules pick for the first argument, its count. */
  format(key: string, ...args: string[]): string;
}

/** Replaces `%@` and the integer specifiers `%d`, `%ld`, `%lld` (in order; `%N$@`, `%N$lld` by
 * position) with `args`; `%%` is a percent sign. A plural catalog string must use an integer
 * specifier, which Xcode's catalog compiler requires of a plural variation. */
export function formatString(text: string, args: readonly string[]): string {
  let next = 0;
  return text.replace(/%(?:(\d+)\$)?(?:@|l{0,2}d)|%%/g, (match, position: string | undefined) => {
    if (match === "%%") return "%";
    const index = position ? Number(position) - 1 : next++;
    return args[index] ?? "";
  });
}

export function createStrings(table: StringTable, tags: readonly string[] = navigatorLanguages()): Strings {
  const language = resolveLanguage(tags, Object.keys(table));
  followDocumentLanguage(Object.keys(table));
  setDocumentLanguage(language);
  const local = table[language] ?? {};
  const english = table.en ?? {};
  const t = (key: string) => local[key] ?? english[key] ?? key;
  const rules = new Intl.PluralRules(language);
  // A plural string's text for the count, else the locale's plain text for the key (a catalog that
  // gave this language no plural forms), else English.
  const form = (key: string, args: readonly string[]) => {
    if (!(`${key}#other` in english)) return t(key);
    const plural = `${key}#${rules.select(Number(args[0] ?? 0))}`;
    return local[plural] ?? local[key] ?? english[plural] ?? english[`${key}#other`] ?? key;
  };
  return {
    language,
    t,
    format: (key, ...args) => formatString(form(key, args), args),
  };
}

function navigatorLanguages(): readonly string[] {
  const nav = globalThis.document?.defaultView?.navigator ?? globalThis.navigator;
  return nav?.languages?.length ? nav.languages : [nav?.language ?? "en"];
}

// A document owns one languagechange listener, shared by every string table on the page.
const documentLanguages = new WeakMap<Document, { available: readonly string[] }>();

/** Updates the page metadata for the locale actually selected by its string catalog. */
export function setDocumentLanguage(language: string): void {
  const root = globalThis.document?.documentElement;
  if (!root) return;
  root.lang = language;
  root.dir = isRtlLanguage(language) ? "rtl" : "ltr";
}

function followDocumentLanguage(available: readonly string[]): void {
  const doc = globalThis.document;
  if (!doc?.documentElement || documentLanguages.has(doc)) return;
  const state = { available };
  documentLanguages.set(doc, state);
  doc.defaultView?.addEventListener("languagechange", () => {
    setDocumentLanguage(resolveLanguage(navigatorLanguages(), state.available));
  });
}
