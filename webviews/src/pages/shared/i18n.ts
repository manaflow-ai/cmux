// Page strings come from xcstrings tables (scripts/pages/gen-strings.mjs writes
// `<page>/generated/strings.json`); no string lives only in TypeScript. The page picks the app's
// language from `navigator.languages`, which WebKit sets from the app's preferred localizations.

export type StringTable = Record<string, Record<string, string>>;

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
  /** `t(key)` with printf-style object placeholders (`%@`, `%1$@`) replaced by `args`. */
  format(key: string, ...args: string[]): string;
}

/** Replaces `%@` (in order) and `%N$@` (by position) with `args`; `%%` is a percent sign. */
export function formatString(text: string, args: readonly string[]): string {
  let next = 0;
  return text.replace(/%(?:(\d+)\$)?@|%%/g, (match, position: string | undefined) => {
    if (match === "%%") return "%";
    const index = position ? Number(position) - 1 : next++;
    return args[index] ?? "";
  });
}

export function createStrings(table: StringTable, tags: readonly string[] = navigatorLanguages()): Strings {
  const language = resolveLanguage(tags, Object.keys(table));
  const local = table[language] ?? {};
  const english = table.en ?? {};
  const t = (key: string) => local[key] ?? english[key] ?? key;
  return {
    language,
    t,
    format: (key, ...args) => formatString(t(key), args),
  };
}

function navigatorLanguages(): readonly string[] {
  if (typeof navigator === "undefined") return ["en"];
  return navigator.languages?.length ? navigator.languages : [navigator.language ?? "en"];
}
