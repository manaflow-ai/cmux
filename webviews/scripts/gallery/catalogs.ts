// Which page string tables a string catalog change reaches, key by key, for gallery routing (touched.ts).
//
// gen-strings.mjs's PAGES says, for each page, the `generated/strings.json` table it writes and the catalogs
// (and, per catalog, the keys) it reads. A changed catalog reaches a page only when one of the keys that page
// takes from it changed: added, removed, or any localization of it edited. The pages import their table like
// any module, so touched.ts places the table on the entries whose imports (or whose host frame's imports)
// reach it. Before, every catalog change rendered every entry (867 job-hours a day of gallery health on
// 2026-11-16, cmuxterm-hq#12794). A catalog no page lists, or one whose base or head text is not JSON, is
// still global: the caller renders everything.
//
//   catalogTables(changed, readBase)  -> {tables: {"webviews/src/pages/x/generated/strings.json": [catalog]},
//                                        inert: [catalog with no page key changed], global: [catalog no page lists]}
import fs from "node:fs";
import path from "node:path";
import { LOCALES, PAGES } from "../pages/gen-strings.mjs";

type Catalog = { file: string; keys?: (all: string[]) => Iterable<string> };
type Page = { out: string; catalogs: Catalog[]; inputs?: string[]; splitLocales?: boolean };

export type CatalogRoute = {
  /** A page table (repo path) a catalog change reaches, with the catalogs that reach it. */
  tables: Record<string, string[]>;
  /** Catalogs whose change reaches no page's keys: they change no gallery render. */
  inert: string[];
  /** Catalogs no page lists, or that could not be read: every entry renders. */
  global: string[];
};

export const isCatalog = (repoPath: string) => repoPath.endsWith(".xcstrings");

/** The keys whose catalog entry differs between two catalog texts (added, removed or edited). */
export function changedKeys(head: string | undefined, base: string | undefined): Set<string> | undefined {
  let headStrings: Record<string, unknown>;
  let baseStrings: Record<string, unknown>;
  try {
    headStrings = head === undefined ? {} : (JSON.parse(head).strings ?? {});
    baseStrings = base === undefined ? {} : (JSON.parse(base).strings ?? {});
  } catch {
    return undefined;
  }
  const out = new Set<string>();
  for (const key of new Set([...Object.keys(headStrings), ...Object.keys(baseStrings)]))
    if (JSON.stringify(headStrings[key]) !== JSON.stringify(baseStrings[key])) out.add(key);
  return out;
}

/** The keys a page takes from a catalog whose keys are `all` (its `keys` filter, or every key). */
function pageKeys(catalog: Catalog, all: string[]): Set<string> {
  try {
    return new Set(catalog.keys ? catalog.keys(all) : all);
  } catch {
    // A filter that reads another file (the settings schema) and cannot: take every key.
    return new Set(all);
  }
}

const keysOf = (text: string | undefined): string[] => {
  try {
    return text === undefined ? [] : Object.keys(JSON.parse(text).strings ?? {});
  } catch {
    return [];
  }
};

/**
 * Routes changed catalogs (repo paths) to the page tables whose keys they change. `readHead` and `readBase`
 * give a catalog's text at the change and at its base (undefined when the file is absent there).
 */
export function catalogTables(
  changed: string[],
  readHead: (repoPath: string) => string | undefined,
  readBase: (repoPath: string) => string | undefined,
  pages: Record<string, Page> = PAGES as Record<string, Page>,
): CatalogRoute {
  const route: CatalogRoute = { tables: {}, inert: [], global: [] };
  for (const file of changed.filter(isCatalog)) {
    const readers = Object.values(pages).flatMap((page) =>
      page.catalogs.filter((catalog) => catalog.file === file).map((catalog) => ({ page, catalog })),
    );
    const head = readHead(file);
    const base = readBase(file);
    const keys = changedKeys(head, base);
    if (!readers.length || keys === undefined) {
      route.global.push(file);
      continue;
    }
    const all = [...new Set([...keysOf(head), ...keysOf(base)])];
    let reached = false;
    for (const { page, catalog } of readers) {
      const taken = pageKeys(catalog, all);
      if (![...keys].some((key) => taken.has(key))) continue;
      reached = true;
      for (const table of tablesOf(page)) (route.tables[table] ??= []).push(file);
    }
    if (!reached) route.inert.push(file);
  }
  return route;
}

/** The files a page's strings write: its table and, for a split page, its locale tables and loaders. */
function tablesOf(page: Page): string[] {
  if (!page.splitLocales) return [page.out];
  const dir = path.posix.dirname(page.out);
  return [page.out, `${dir}/localeLoaders.ts`, ...LOCALES.map((locale: string) => `${dir}/locales/${locale}.json`)];
}

/** A catalog's text in the checkout (repo path), or undefined. */
export function readCheckout(repoRoot: string): (repoPath: string) => string | undefined {
  return (repoPath) => {
    try {
      return fs.readFileSync(path.join(repoRoot, repoPath), "utf8");
    } catch {
      return undefined;
    }
  };
}

/** A catalog's text at a git revision, or undefined when it is absent there. */
export function readRevision(repoRoot: string, rev: string): (repoPath: string) => string | undefined {
  return (repoPath) => {
    const shown = Bun.spawnSync(["git", "-C", repoRoot, "show", `${rev}:${repoPath}`], { stderr: "ignore" });
    return shown.exitCode === 0 ? shown.stdout.toString() : undefined;
  };
}
