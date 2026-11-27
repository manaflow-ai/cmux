// User languages for the diff viewer: the host reads `<config dir>/diff/languages/` (next to
// cmux.json, so CMUX_NEXT_CONFIG_FILE moves it) and hands the page every file as text, unparsed.
// This module turns those files into validated grammars and the override map. A file that is
// missing, unreadable or invalid is skipped with a warning and every other file still applies.
//
// Folder layout:
//   <name>.language.json   manifest, one per language (fields below)
//   <name>.tmLanguage.json  the TextMate grammar a manifest names (JSON)
//   overrides.json          {"extensions": {"h": "c"}, "filenames": {"BUILD": "python"}}
//
// Manifest fields: `id` (required), `grammar` (a file in the folder, default `<id>.tmLanguage.json`,
// or the grammar object inline), `scopeName` (defaults to the grammar's), `extensions`,
// `filenames`, `aliases`, `embeddedLanguages` (ids loaded with the grammar, for `include`s of
// another language's scope).
import type { LanguageOverrides } from "./detect";

/// One file of the languages folder, as the host delivers it. `path` is relative to the folder.
export type DiffLanguagePackFile = { path: string; text: string };

/// What the host sends: the whole folder, every time it changes. Swift writes it into the page
/// config (`payload.languages`) and pushes changes to `window.cmuxDiffViewerLanguages.apply`;
/// the pane protocol will carry the same object.
export type DiffLanguagePack = { files: DiffLanguagePackFile[] };

export type CustomGrammar = {
  id: string;
  aliases: string[];
  extensions: string[];
  filenames: string[];
  embeddedLanguages: string[];
  scopeName: string;
  grammar: Record<string, unknown>;
  /// Content hash of the grammar and its embedded list; changes whenever the language does.
  fingerprint: string;
};

export type ParsedLanguagePack = {
  languages: CustomGrammar[];
  overrides: LanguageOverrides;
  warnings: string[];
};

export const MANIFEST_SUFFIX = ".language.json";
export const OVERRIDES_FILE = "overrides.json";
const languageIdPattern = /^[a-z0-9][a-z0-9+#._-]{0,63}$/i;

export function parseDiffLanguagePack(pack: unknown): ParsedLanguagePack {
  const warnings: string[] = [];
  const files = packFiles(pack, warnings);
  const byPath = new Map(files.map((file) => [normalizePath(file.path), file.text]));
  const languages: CustomGrammar[] = [];
  const seen = new Set<string>();
  for (const [path, text] of byPath) {
    if (!path.endsWith(MANIFEST_SUFFIX)) continue;
    const language = parseManifest(path, text, byPath, warnings);
    if (language == null) continue;
    if (seen.has(language.id.toLowerCase())) {
      warnings.push(`${path}: language "${language.id}" is defined twice; skipped`);
      continue;
    }
    seen.add(language.id.toLowerCase());
    languages.push(language);
  }
  const overridesText = byPath.get(OVERRIDES_FILE);
  const overrides = overridesText == null ? {} : parseOverrides(overridesText, warnings);
  return { languages, overrides, warnings };
}

function packFiles(pack: unknown, warnings: string[]): DiffLanguagePackFile[] {
  if (pack == null) return [];
  const files = (pack as { files?: unknown }).files;
  if (!Array.isArray(files)) {
    warnings.push("language pack: `files` is not an array; ignored");
    return [];
  }
  return files.filter((file): file is DiffLanguagePackFile => {
    const ok = typeof file?.path === "string" && typeof file?.text === "string";
    if (!ok) warnings.push("language pack: a file entry without a string path and text was skipped");
    return ok;
  });
}

function parseManifest(
  path: string,
  text: string,
  files: Map<string, string>,
  warnings: string[],
): CustomGrammar | undefined {
  const manifest = parseJSON(path, text, warnings);
  if (!isRecord(manifest)) {
    if (manifest !== undefined) warnings.push(`${path}: the manifest is not a JSON object; skipped`);
    return undefined;
  }
  const id = typeof manifest.id === "string" ? manifest.id.trim() : "";
  if (!languageIdPattern.test(id) || id === "text" || id === "ansi") {
    warnings.push(`${path}: \`id\` must be a short name such as "my-lang" (not text or ansi); skipped`);
    return undefined;
  }

  let grammar: unknown;
  const grammarSource = manifest.grammar ?? `${id}.tmLanguage.json`;
  if (typeof grammarSource === "string") {
    const grammarPath = normalizePath(joinPath(dirname(path), grammarSource));
    const grammarText = files.get(grammarPath);
    if (grammarText == null) {
      warnings.push(`${path}: grammar file ${grammarPath} is missing; skipped`);
      return undefined;
    }
    grammar = parseJSON(grammarPath, grammarText, warnings);
    if (grammar === undefined) return undefined;
  } else {
    grammar = grammarSource;
  }
  const grammarProblem = textMateGrammarProblem(grammar);
  if (grammarProblem != null) {
    warnings.push(`${path}: the grammar ${grammarProblem}; skipped`);
    return undefined;
  }
  const grammarObject = grammar as Record<string, unknown>;
  const scopeName =
    typeof manifest.scopeName === "string" && manifest.scopeName.trim() !== ""
      ? manifest.scopeName.trim()
      : String(grammarObject.scopeName);

  const embeddedLanguages = stringList(path, "embeddedLanguages", manifest.embeddedLanguages, warnings);
  return {
    id,
    aliases: stringList(path, "aliases", manifest.aliases, warnings),
    extensions: stringList(path, "extensions", manifest.extensions, warnings),
    filenames: stringList(path, "filenames", manifest.filenames, warnings),
    embeddedLanguages,
    scopeName,
    grammar: { ...grammarObject, scopeName },
    fingerprint: fingerprint(`${scopeName}\n${embeddedLanguages.join(",")}\n${JSON.stringify(grammarObject)}`),
  };
}

/// Why a value is not a usable TextMate grammar, or null when it is one.
export function textMateGrammarProblem(grammar: unknown): string | null {
  if (!isRecord(grammar)) return "is not a JSON object";
  if (typeof grammar.scopeName !== "string" || grammar.scopeName.trim() === "") return "has no `scopeName`";
  const hasPatterns = Array.isArray(grammar.patterns);
  const hasInjections = isRecord(grammar.injections);
  if (!hasPatterns && !hasInjections) return "has neither `patterns` nor `injections`";
  if (grammar.patterns !== undefined && !Array.isArray(grammar.patterns))
    return "has a `patterns` that is not an array";
  if (grammar.repository !== undefined && !isRecord(grammar.repository)) {
    return "has a `repository` that is not an object";
  }
  const badRule = firstBadRule(grammar.patterns) ?? firstBadRepository(grammar.repository);
  return badRule;
}

function firstBadRepository(repository: unknown): string | null {
  if (!isRecord(repository)) return null;
  for (const [name, rule] of Object.entries(repository)) {
    if (!isRecord(rule)) return `has a repository entry "${name}" that is not an object`;
    const problem = firstBadRule(rule.patterns);
    if (problem != null) return problem;
  }
  return null;
}

function firstBadRule(patterns: unknown): string | null {
  if (!Array.isArray(patterns)) return null;
  for (const rule of patterns) {
    if (!isRecord(rule)) return "has a pattern that is not an object";
    for (const key of ["match", "begin", "end", "while"]) {
      if (rule[key] !== undefined && typeof rule[key] !== "string")
        return `has a pattern whose \`${key}\` is not a string`;
    }
    if (rule.begin !== undefined && rule.end === undefined && rule.while === undefined) {
      return "has a `begin` pattern without `end` or `while`";
    }
    const nested = firstBadRule(rule.patterns);
    if (nested != null) return nested;
  }
  return null;
}

function parseOverrides(text: string, warnings: string[]): LanguageOverrides {
  const value = parseJSON(OVERRIDES_FILE, text, warnings);
  if (value === undefined) return {};
  if (!isRecord(value)) {
    warnings.push(`${OVERRIDES_FILE}: not a JSON object; ignored`);
    return {};
  }
  return {
    extensions: stringMap("extensions", value.extensions, warnings),
    filenames: stringMap("filenames", value.filenames, warnings),
  };
}

function stringMap(field: string, value: unknown, warnings: string[]): Record<string, string> {
  if (value === undefined) return {};
  if (!isRecord(value)) {
    warnings.push(`${OVERRIDES_FILE}: \`${field}\` is not an object; ignored`);
    return {};
  }
  const result: Record<string, string> = {};
  for (const [key, language] of Object.entries(value)) {
    if (typeof language === "string" && key.trim() !== "") result[key.trim()] = language.trim();
    else warnings.push(`${OVERRIDES_FILE}: \`${field}.${key}\` is not a language name; ignored`);
  }
  return result;
}

function stringList(path: string, field: string, value: unknown, warnings: string[]): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) {
    warnings.push(`${path}: \`${field}\` is not an array; ignored`);
    return [];
  }
  return value
    .filter((entry): entry is string => typeof entry === "string" && entry.trim() !== "")
    .map((s) => s.trim());
}

function parseJSON(path: string, text: string, warnings: string[]): unknown {
  try {
    return JSON.parse(text);
  } catch (error) {
    warnings.push(`${path}: invalid JSON (${error instanceof Error ? error.message : String(error)}); skipped`);
    return undefined;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizePath(path: string): string {
  const parts: string[] = [];
  for (const part of path.replace(/\\/g, "/").split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return parts.join("/");
}

function dirname(path: string): string {
  const slash = path.lastIndexOf("/");
  return slash < 0 ? "" : path.slice(0, slash);
}

function joinPath(directory: string, path: string): string {
  return directory === "" ? path : `${directory}/${path}`;
}

/// FNV-1a, 32 bit, as hex: stable, and enough to tell grammar versions apart.
function fingerprint(text: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < text.length; index++) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}
