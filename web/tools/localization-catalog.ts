import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  isStructurallySame,
  parse,
  type MessageFormatElement,
} from "@formatjs/icu-messageformat-parser";

export const parityLocales = [
  "en",
  "ja",
  "zh-CN",
  "zh-TW",
  "ko",
  "de",
  "es",
  "fr",
  "ar",
] as const;

export type ParityLocale = (typeof parityLocales)[number];
export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

export type CatalogLeaf = { path: string; value: JsonValue };
export type TranslationEntry = {
  path: string;
  source: string;
  translation?: string;
  placeholders: string[];
  richTextTags: string[];
};

export type CatalogIssue = {
  locale: string;
  path: string;
  message: string;
  source?: string;
  value?: JsonValue;
};

const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const messagesDirectory = path.join(webRoot, "messages");

export const productLabelValues = new Set([
  "Android",
  "Alacritty",
  "Amazon Bedrock",
  "Claude",
  "Claude Code",
  "Claude Code Teams - cmux",
  "CodeRouter",
  "Codex",
  "CodexBar",
  "Cursor",
  "Devin",
  "Discord",
  "GitHub",
  "Ghostty",
  "GPT 5.6 Sol",
  "Grok Build CLI",
  "Herdr",
  "Homebrew",
  "iOS",
  "iOS TestFlight",
  "iTerm2",
  "Kitty",
  "Linux",
  "macOS",
  "Node.js",
  "OpenCode",
  "OpenCode Go",
  "Python",
  "Pro",
  "SSH",
  "Tailscale",
  "Terminal.app",
  "Twitter",
  "Warp",
  "WezTerm",
  "Windows",
  "Windsurf",
  "WireGuard",
  "X / Twitter",
  "YouTube",
  "Zed",
  "cmux",
  "cmux Cloud",
  "cmux iOS",
  "cmux NIGHTLY",
  "cmux Pro",
  "cmux TUI",
  "cmux Vault",
  "coderouter",
  "opencode",
  "tmux",
  "cmux SSH",
  "GitHub Copilot CLI",
  "oh-my-pi",
  "oh-my-pi - cmux",
  "oh-my-codex",
  "oh-my-opencode",
]);

export const booleanMessageTokens = new Set(["true", "false"]);

const identityAllowedValues = new Set([
  ...productLabelValues,
  ...booleanMessageTokens,
  "API",
  "CLI",
  "EULA",
  "FAQ",
  "GPU",
  "GPU / CPU",
  "Intel",
  "IT",
  "CPU",
  "JSON",
  "LinkedIn",
  "MDM",
  "GPU (libghostty)",
  "OAuth JSON",
  "TUI",
  "Unix",
  "cmux.json",
  "founders@manaflow.com",
  "sk-ant-...",
  "sk-...",
  "you@example.com",
  "Cmd+Control+U",
  "Cmd+Option+U",
  "Cmd+Shift+U",
  "PreToolUse",
  "PreToolUse, PermissionRequest",
  "PreToolUse, PostToolUse",
  "WebAuthn",
  "macOS + Linux + Windows",
  "macOS, Linux",
  "macOS, Linux, Windows",
  "pre_tool_call, post_tool_call, pre_approval_request, post_approval_response",
  "beforeShellExecution",
  "Pi",
  "San Francisco",
  "Linux · x64",
  "coderouter — cmux",
  "Pro",
  "Claude OAuth",
  "Codex OAuth",
  "Claude Code OAuth",
  "© {year} Manaflow",
  "Ghostty VT",
  "TextBox (Beta)",
  "PermissionRequest",
  "assistant",
  "Dock",
]);

const forbiddenTranslationMarkerPatterns = [
  /\b(?:TODO|FIXME|TBD)\b/u,
  /\b(?:machine[- ]translated|machine translation|translation pending|translate me)\b/iu,
  /(?:\[\[(?:TODO|FIXME|TBD|TRANSLATE|MACHINE_TRANSLATION)[^\]]*\]\]|<translation-needed>)/iu,
  /(?:CMUXTOKEN|__CMUXPH)/iu,
];

function isObject(value: JsonValue): value is { [key: string]: JsonValue } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function flattenCatalog(value: JsonValue, prefix = ""): CatalogLeaf[] {
  if (Array.isArray(value)) {
    return value.flatMap((item, index) =>
      flattenCatalog(item, prefix ? `${prefix}.${index}` : `${index}`),
    );
  }
  if (isObject(value)) {
    return Object.entries(value).flatMap(([key, item]) =>
      flattenCatalog(item, prefix ? `${prefix}.${key}` : key),
    );
  }
  return [{ path: prefix, value }];
}

function matchingBraces(value: string): string[] {
  const matches: string[] = [];
  for (let start = 0; start < value.length; start += 1) {
    if (value[start] !== "{") continue;
    let depth = 0;
    for (let end = start; end < value.length; end += 1) {
      if (value[end] === "{") depth += 1;
      if (value[end] === "}") depth -= 1;
      if (depth === 0) {
        matches.push(value.slice(start, end + 1));
        start = end;
        break;
      }
    }
  }
  return matches;
}

export function syntaxTokens(value: string): {
  placeholders: string[];
  richTextTags: string[];
} {
  return {
    placeholders: matchingBraces(value),
    richTextTags: value.match(/<\/?[a-z][^>]*>/giu) ?? [],
  };
}

function richTextTagContentShape(value: string): string[] {
  const shapes: string[] = [];
  const stack: { name: string; hasText: boolean; index: number }[] = [];
  const tagPattern = /<\/?([a-z][\w-]*)(?:\s[^>]*?)?\s*\/?>/giu;
  let cursor = 0;

  for (const match of value.matchAll(tagPattern)) {
    const tagStart = match.index ?? 0;
    if (value.slice(cursor, tagStart).trim() && stack.length > 0) {
      stack[stack.length - 1].hasText = true;
    }

    const token = match[0];
    const name = match[1].toLowerCase();
    if (token.startsWith("</")) {
      const frame = stack.pop();
      if (!frame || frame.name !== name) return [];
      shapes[frame.index] = `${frame.name}:${frame.hasText ? "text" : "empty"}`;
      if (frame.hasText && stack.length > 0) {
        stack[stack.length - 1].hasText = true;
      }
    } else if (!token.endsWith("/>")) {
      const index = shapes.length;
      shapes.push(`${name}:empty`);
      stack.push({ name, hasText: false, index });
    } else {
      shapes.push(`${name}:self`);
    }
    cursor = tagStart + token.length;
  }

  if (value.slice(cursor).trim() && stack.length > 0) {
    stack[stack.length - 1].hasText = true;
  }
  return stack.length === 0 ? shapes : [];
}

function icuStructure(value: string): MessageFormatElement[] | null {
  try {
    return parse(value);
  } catch {
    return null;
  }
}

function hasMatchingIcuStructure(source: string, translation: string): boolean {
  if (!source.includes("{") && !translation.includes("{")) return true;
  const sourceAst = icuStructure(source);
  const translationAst = icuStructure(translation);
  if (sourceAst && translationAst) {
    return isStructurallySame(sourceAst, translationAst).success;
  }
  if (sourceAst && !translationAst) return false;
  const sourceSimplePlaceholders = matchingBraces(source).filter((token) =>
    /^[{][\w.-]+[}]$/u.test(token),
  );
  const translationSimplePlaceholders = matchingBraces(translation).filter((token) =>
    /^[{][\w.-]+[}]$/u.test(token),
  );
  return (
    JSON.stringify(sourceSimplePlaceholders) ===
    JSON.stringify(translationSimplePlaceholders)
  );
}

export function isEnglishIdentityAllowed(pathname: string, value: string): boolean {
  if (identityAllowedValues.has(value)) return true;
  if (/^(?:https?:\/\/\S+|mailto:\S+|tel:\S+|[\w.+-]+@[\w.-]+\.[a-z]{2,})$/iu.test(value)) {
    return true;
  }
  if (/^[\d\s$,+./:#?=&%()\[\]{}<>_@-]+$/u.test(value)) return true;
  if (/^\{[\w.-]+\}(?:\s*·\s*\{[\w.-]+\})?$/u.test(value)) return true;
  if (
    value.includes("\n") &&
    value
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .every((line) =>
        /^(?:[$>#]\s*)?(?:[A-Z_][A-Z\d_]*=|(?:cmux|git|bun|npm|curl|ssh|brew|cargo|zig|python|node|npx|pnpm|docker|cd|mkdir|cat|echo|export|xcrun)\b|[`{}[\]]|https?:\/\/)/u.test(
          line,
        ),
      )
  ) {
    return true;
  }
  return false;
}

function hasForbiddenTranslationMarker(value: string): boolean {
  return forbiddenTranslationMarkerPatterns.some((pattern) => pattern.test(value));
}

function hasMatchingLeafValue(source: JsonValue, translation: JsonValue): boolean {
  return typeof source === "string" && !booleanMessageTokens.has(source)
    ? typeof translation === "string"
    : source === translation;
}

export async function readCatalog(locale: string): Promise<JsonValue> {
  return JSON.parse(
    await readFile(path.join(messagesDirectory, `${locale}.json`), "utf8"),
  ) as JsonValue;
}

export async function catalogLeaves(locale: string): Promise<CatalogLeaf[]> {
  return flattenCatalog(await readCatalog(locale));
}

export async function validateCatalog(
  locale: ParityLocale,
  english: JsonValue,
  translation: JsonValue,
): Promise<CatalogIssue[]> {
  const issues: CatalogIssue[] = [];
  const englishLeaves = flattenCatalog(english);
  const translationLeaves = flattenCatalog(translation);
  const englishByPath = new Map(englishLeaves.map((leaf) => [leaf.path, leaf]));
  const translationByPath = new Map(
    translationLeaves.map((leaf) => [leaf.path, leaf]),
  );

  for (const englishLeaf of englishLeaves) {
    const translatedLeaf = translationByPath.get(englishLeaf.path);
    if (!translatedLeaf) {
      issues.push({
        locale,
        path: englishLeaf.path,
        message: "missing key",
        source: typeof englishLeaf.value === "string" ? englishLeaf.value : undefined,
      });
      continue;
    }
    if (!hasMatchingLeafValue(englishLeaf.value, translatedLeaf.value)) {
      issues.push({
        locale,
        path: englishLeaf.path,
        message: "invalid message value",
        source: typeof englishLeaf.value === "string" ? englishLeaf.value : undefined,
        value: translatedLeaf.value,
      });
      continue;
    }
    if (
      typeof translatedLeaf.value === "string" &&
      translatedLeaf.value.trim().length === 0
    ) {
      issues.push({ locale, path: englishLeaf.path, message: "empty value" });
    }
    if (
      locale !== "en" &&
      typeof translatedLeaf.value === "string" &&
      hasForbiddenTranslationMarker(translatedLeaf.value)
    ) {
      issues.push({
        locale,
        path: englishLeaf.path,
        message: "forbidden translation marker",
        source: typeof englishLeaf.value === "string" ? englishLeaf.value : undefined,
        value: translatedLeaf.value,
      });
    }
    if (typeof englishLeaf.value === "string" && typeof translatedLeaf.value === "string") {
      if (productLabelValues.has(englishLeaf.value) && englishLeaf.value !== translatedLeaf.value) {
        issues.push({
          locale,
          path: englishLeaf.path,
          message: "translated product name",
          source: englishLeaf.value,
          value: translatedLeaf.value,
        });
      }
      const sourceTokens = syntaxTokens(englishLeaf.value);
      if (!hasMatchingIcuStructure(englishLeaf.value, translatedLeaf.value)) {
        issues.push({
          locale,
          path: englishLeaf.path,
          message: "placeholder mismatch",
          source: englishLeaf.value,
          value: translatedLeaf.value,
        });
      }
      const translatedTokens = syntaxTokens(translatedLeaf.value);
      if (
        JSON.stringify(sourceTokens.richTextTags) !==
          JSON.stringify(translatedTokens.richTextTags) ||
        JSON.stringify(richTextTagContentShape(englishLeaf.value)) !==
          JSON.stringify(richTextTagContentShape(translatedLeaf.value))
      ) {
        issues.push({
          locale,
          path: englishLeaf.path,
          message: "rich-text tag mismatch",
          source: englishLeaf.value,
          value: translatedLeaf.value,
        });
      }
      if (
        locale !== "en" &&
        englishLeaf.value === translatedLeaf.value &&
        !isEnglishIdentityAllowed(englishLeaf.path, englishLeaf.value)
      ) {
        issues.push({
          locale,
          path: englishLeaf.path,
          message: "English-identical value",
          source: englishLeaf.value,
          value: translatedLeaf.value,
        });
      }
    }
  }

  for (const translatedLeaf of translationLeaves) {
    if (!englishByPath.has(translatedLeaf.path)) {
      issues.push({
        locale,
        path: translatedLeaf.path,
        message: "stale key",
        value: translatedLeaf.value,
      });
    }
  }
  return issues;
}

function setLeaf(
  source: JsonValue,
  translations: Map<string, JsonValue>,
  prefix = "",
): JsonValue {
  if (Array.isArray(source)) {
    return source.map((value, index) =>
      setLeaf(value, translations, prefix ? `${prefix}.${index}` : `${index}`),
    );
  }
  if (isObject(source)) {
    return Object.fromEntries(
      Object.entries(source).map(([key, value]) => [
        key,
        setLeaf(value, translations, prefix ? `${prefix}.${key}` : key),
      ]),
    );
  }
  return translations.get(prefix) ?? source;
}

export function mergeTranslations(
  english: JsonValue,
  existing: JsonValue,
  translations: Map<string, string>,
): JsonValue {
  const existingByPath = new Map(flattenCatalog(existing).map((leaf) => [leaf.path, leaf.value]));
  const values = new Map<string, JsonValue>();
  for (const leaf of flattenCatalog(english)) {
    const translated = translations.get(leaf.path);
    if (translated !== undefined) values.set(leaf.path, translated);
    else if (typeof existingByPath.get(leaf.path) === "string") {
      values.set(leaf.path, existingByPath.get(leaf.path) as string);
    }
  }
  return setLeaf(english, values);
}

function entriesNeedingTranslation(
  english: JsonValue,
  translation: JsonValue,
  locale: ParityLocale,
): TranslationEntry[] {
  const translatedByPath = new Map(flattenCatalog(translation).map((leaf) => [leaf.path, leaf.value]));
  return flattenCatalog(english).flatMap((leaf) => {
    if (typeof leaf.value !== "string") return [];
    const current = translatedByPath.get(leaf.path);
    if (
      locale === "en" ||
      (typeof current === "string" &&
        current !== leaf.value &&
        current.trim().length > 0)
    ) {
      return [];
    }
    if (isEnglishIdentityAllowed(leaf.path, leaf.value)) return [];
    const tokens = syntaxTokens(leaf.value);
    return [
      {
        path: leaf.path,
        source: leaf.value,
        placeholders: tokens.placeholders,
        richTextTags: tokens.richTextTags,
      },
    ];
  });
}

async function exportEntries(locale: ParityLocale, batchSize: number, output: string) {
  const english = await readCatalog("en");
  const translation = await readCatalog(locale);
  const entries = entriesNeedingTranslation(english, translation, locale);
  await mkdir(path.resolve(output), { recursive: true });
  const batches = [];
  for (let index = 0; index < entries.length; index += batchSize) {
    batches.push(entries.slice(index, index + batchSize));
  }
  for (const [index, batch] of batches.entries()) {
    const destination = path.resolve(
      output,
      `${locale}.batch-${String(index + 1).padStart(3, "0")}.json`,
    );
    await writeFile(
      destination,
      `${JSON.stringify({ locale, batch: index + 1, entries: batch }, null, 2)}\n`,
    );
  }
  console.log(JSON.stringify({ locale, entries: entries.length, batches: batches.length }));
}

async function readTranslationInputs(inputs: string[]): Promise<Map<string, string>> {
  const translations = new Map<string, string>();
  for (const input of inputs) {
    const content = JSON.parse(await readFile(path.resolve(input), "utf8")) as
      | Record<string, string>
      | { entries: TranslationEntry[] };
    const entries =
      "entries" in content && Array.isArray(content.entries)
        ? (content.entries as TranslationEntry[])
        : undefined;
    if (entries) {
      for (const entry of entries) {
        if (entry.translation !== undefined) translations.set(entry.path, entry.translation);
      }
    } else {
      for (const [key, value] of Object.entries(content)) translations.set(key, value);
    }
  }
  return translations;
}

async function main() {
  const [command = "audit", ...args] = process.argv.slice(2);
  const english = await readCatalog("en");
  if (command === "audit") {
    for (const locale of parityLocales.slice(1)) {
      const translation = await readCatalog(locale);
      const issues = await validateCatalog(locale, english, translation);
      const missing = issues.filter((issue) => issue.message === "missing key").length;
      const stale = issues.filter((issue) => issue.message === "stale key").length;
      const identical = issues.filter((issue) => issue.message === "English-identical value").length;
      console.log(JSON.stringify({ locale, missing, stale, identical, issues: issues.length }));
    }
    return;
  }
  if (command === "validate") {
    const locales = args.length > 0 ? args : [...parityLocales.slice(1)];
    const issues = [];
    for (const locale of locales as ParityLocale[]) {
      issues.push(...(await validateCatalog(locale, english, await readCatalog(locale))));
    }
    if (issues.length > 0) {
      console.error(JSON.stringify(issues, null, 2));
      process.exitCode = 1;
      return;
    }
    console.log(`Validated ${locales.length} locale catalogs against en.json.`);
    return;
  }
  if (command === "export") {
    const locale = args[0] as ParityLocale | undefined;
    if (!locale || locale === "en") throw new Error("export requires a non-English locale");
    const batchSize = Number(args[1] ?? 100);
    if (!Number.isInteger(batchSize) || batchSize < 1) {
      throw new Error("export batch size must be a positive integer");
    }
    const output = path.resolve(args[2] ?? "localization-batches");
    await exportEntries(locale, batchSize, output);
    return;
  }
  if (command === "merge") {
    const locale = args[0] as ParityLocale | undefined;
    const output = args[1];
    const inputs = args.slice(2);
    if (!locale || !output || inputs.length === 0) {
      throw new Error("merge requires <locale> <output> <translation-json>...");
    }
    const merged = mergeTranslations(
      english,
      await readCatalog(locale),
      await readTranslationInputs(inputs),
    );
    await writeFile(path.resolve(output), `${JSON.stringify(merged, null, 2)}\n`);
    return;
  }
  if (command === "list-batches") {
    const entries = await readdir(path.resolve(args[0] ?? "localization-batches"));
    console.log(entries.filter((entry) => entry.endsWith(".json")).join("\n"));
    return;
  }
  throw new Error(`Unknown command: ${command}`);
}

const entrypoint = process.argv[1]
  ? path.resolve(process.argv[1])
  : undefined;
if (entrypoint === fileURLToPath(import.meta.url)) await main();
