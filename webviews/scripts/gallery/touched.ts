#!/usr/bin/env bun
// Which gallery entries a change touches for an explicitly requested local matrix run:
// an entry is touched when a changed file is its own `*.gallery.ts`, or is reachable through
// relative imports from that file or from one of its `covers`. Following imports catches what
// `covers` leaves out (a hook, a shared helper). A stylesheet is global to the page that loads it,
// so a changed stylesheet of an entry's host (the agent pane's shipped CSS, a page's imports)
// touches every entry of that host. A change to the gallery itself, the build config or the
// lockfile touches every entry.
//
// `ranked` orders the touched entries by how close each is to the change, for a capped sample
// (gallery-advisory.yml renders the first few): its own source first (its gallery file, a file it
// covers, a stylesheet one of those imports), then a gallery file that names a changed component,
// then entries that import a changed file (fewest hops first), then entries beside a changed file
// in the same folder, then entries reached only through a host stylesheet, then everything else a
// broad change re-renders. A shared stylesheet touches every entry; the ranking still puts the
// component that owns it first.
//
//   bun scripts/gallery/touched.ts --changed changed.txt            # one repo path per line
//   -> {"all": false, "entries": ["agent-pane.composer"], "reasons": {...}, "ranked": [{"id": ..., "tier": 0, ...}]}
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { agentPaneStylesheets } from "../../dev-server/galleryHost";
import { GENERATED as FEATURE_TIPS, HIGHLIGHTS } from "../pages/gen-feature-tips.mjs";
import { PAGES } from "../pages/gen-strings.mjs";
import { galleryFiles, SRC } from "./entries";

/** Repo paths that re-render every entry when they change. */
const EVERYTHING = [
  /^webviews\/src\/gallery\//,
  /^webviews\/scripts\/gallery\//,
  /^webviews\/dev-server\/galleryHost\.ts$/,
  /^scripts\/cmux-next\/build-agent-pane-web\.sh$/,
  // The pane's sheets and their order (build-agent-pane-web.sh derives the page's <style> from it).
  /^webviews\/src\/agent-session\/acpmux\/dev\.tsx$/,
  // What derives that list (galleryHost.ts runs bundle.mjs --css-inputs-only with these plugins).
  /^webviews\/scripts\/agent-pane\/(bundle|tailwindCompile|jsonParsePlugin|katexStylePlugin)\.mjs$/,
  /^webviews\/vite\.config(\.gallery)?\.ts$/,
  /^webviews\/package\.json$/,
  /^bun\.lock$/,
  /^scripts\/gallery-matrix\//,
  // A string catalog under webviews/src that gen-strings.mjs does not list (derivedTables() routes the
  // ones it does): no import reaches it, and no table names it.
  /^webviews\/src\/.*\.xcstrings$/,
];

/**
 * The build-output tables (repo paths) each source file is compiled into, which entries import instead of
 * the source: a string catalog becomes the `generated/strings.json` of every page gen-strings.mjs lists it
 * for, a What's New highlight becomes the feature tips table (gen-feature-tips.mjs). A change to the
 * source touches the entries that import one of its tables (or whose host's stage loads it), not every
 * entry: a Settings catalog edit rendered all ~13,000 gallery cases before (cmux#49853).
 */
export function derivedTables(
  changed: string[],
  pages: Record<string, { out: string; catalogs: { file: string }[] }> = PAGES,
): Map<string, string[]> {
  const repo = path.resolve(SRC, "../..");
  const highlights = `${path.relative(repo, HIGHLIGHTS)}/`;
  const tips = path.relative(repo, FEATURE_TIPS);
  const tables = new Map<string, string[]>();
  for (const file of changed) {
    const outs = Object.values(pages)
      .filter((page) => page.catalogs.some((catalog) => catalog.file === file))
      .map((page) => page.out);
    if (file.startsWith(highlights) && file.endsWith(".md")) outs.push(tips);
    if (outs.length) tables.set(file, [...new Set(outs)].sort());
  }
  return tables;
}

const SOURCE_EXTENSIONS = [".ts", ".tsx", ".js", ".mjs", ".css"];
// `new URL("./x.png", import.meta.url)` loads an asset as surely as an import does (ChiefDock's mascots).
const IMPORT = /(?:\bfrom\s*|\bimport\s*\(?\s*|\bnew\s+URL\s*\(\s*)["']([^"']+)["']/g;

/** Why an entry is in the sample, closest first (the tier is the index here). */
export const RANK_REASONS = [
  "own",
  "names",
  "imports",
  "same-folder",
  "host-stylesheet",
  "host-table",
  "everything",
] as const;
export type RankReason = (typeof RANK_REASONS)[number];
/** One touched entry in ranked order: the changed file that put it there and, for imports, the hops. */
export type RankedEntry = { id: string; tier: number; why: RankReason; file: string; distance: number };
export type TouchedEntries = {
  all: boolean;
  entries: string[];
  reasons: Record<string, string[]>;
  ranked: RankedEntry[];
  /** Changed sources routed through the tables built from them: placed exactly, even on no entry
   * (a catalog only an ungalleried page reads renders nothing), so unplaced.py does not fall back. */
  derived: string[];
};
export type EntryRoots = { id: string; host: string; file: string; covers: string[] };

/** The stage module that mounts each kind of entry (src/gallery/frame/). */
const HOST_FRAMES: Record<string, string> = {
  "agent-pane": "gallery/frame/agentPane.ts",
  "markdown-page": "gallery/frame/pages.ts",
  "diff-page": "gallery/frame/pages.ts",
  component: "gallery/frame/component.tsx",
};

/** The stylesheets a host's page loads: the CSS its stage module reaches, and the pane's shipped CSS. */
export function hostStylesheets(
  host: string,
  src: string,
  read: (file: string) => string | undefined,
  paneStylesheets: () => string[],
): string[] {
  const frame = HOST_FRAMES[host];
  const reached = frame ? [...closure([path.join(src, frame)], read)].filter((file) => file.endsWith(".css")) : [];
  return host === "agent-pane" ? [...reached, ...paneStylesheets()] : reached;
}

/** The relative imports of one source file, resolved to files that exist. */
export function importsOf(file: string, read: (file: string) => string | undefined = readSource): string[] {
  const text = read(file);
  if (text === undefined) return [];
  const out: string[] = [];
  for (const match of text.matchAll(IMPORT)) {
    const spec = match[1]!.replace(/\?.*$/, "");
    if (!spec.startsWith(".")) continue;
    const resolved = resolveImport(path.resolve(path.dirname(file), spec), read);
    if (resolved) out.push(resolved);
  }
  return out;
}

function resolveImport(base: string, read: (file: string) => string | undefined): string | undefined {
  const candidates = [
    base,
    ...SOURCE_EXTENSIONS.map((ext) => base + ext),
    ...SOURCE_EXTENSIONS.map((ext) => path.join(base, `index${ext}`)),
  ];
  // A `.js` specifier may name a `.ts` source.
  if (base.endsWith(".js")) candidates.push(base.replace(/\.js$/, ".ts"), base.replace(/\.js$/, ".tsx"));
  return candidates.find((candidate) => path.extname(candidate) !== "" && read(candidate) !== undefined);
}

function readSource(file: string): string | undefined {
  try {
    return fs.statSync(file).isFile() ? fs.readFileSync(file, "utf8") : undefined;
  } catch {
    return undefined;
  }
}

/** Every file reachable from `roots` through relative imports, roots included. */
export function closure(roots: string[], read: (file: string) => string | undefined = readSource): Set<string> {
  const seen = new Set<string>();
  const queue = [...roots];
  while (queue.length) {
    const file = queue.pop()!;
    if (seen.has(file)) continue;
    seen.add(file);
    queue.push(...importsOf(file, read));
  }
  return seen;
}

/** Import hops from `roots` to every reachable file (roots are 0), breadth first. */
export function distances(
  roots: string[],
  read: (file: string) => string | undefined = readSource,
): Map<string, number> {
  const seen = new Map<string, number>();
  let frontier = [...new Set(roots)];
  for (let hops = 0; frontier.length; hops++) {
    const next: string[] = [];
    for (const file of frontier) {
      if (seen.has(file)) continue;
      seen.set(file, hops);
      next.push(...importsOf(file, read).filter((imported) => !seen.has(imported)));
    }
    frontier = next;
  }
  return seen;
}

const COMPONENT_NAME = /^[A-Z][A-Za-z0-9]{3,}$/;

/** Whether a gallery file names a changed file: its src-relative path, or a component's name as a word. */
function names(text: string, changedSrcPath: string): boolean {
  if (text.includes(changedSrcPath)) return true;
  const stem = path.basename(changedSrcPath).replace(/\.[^.]+$/, "");
  return COMPONENT_NAME.test(stem) && new RegExp(`\\b${stem}\\b`).test(text);
}

/** A cover is `dir/File.tsx#Component` or `dir/`, relative to webviews/src. */
function coverFiles(cover: string, src: string): string[] {
  const rel = cover.replace(/#.*$/, "");
  const full = path.join(src, rel);
  if (!rel.endsWith("/")) return [full];
  try {
    return fs
      .readdirSync(full, { recursive: true, encoding: "utf8" })
      .filter((name) => SOURCE_EXTENSIONS.includes(path.extname(name)))
      .map((name) => path.join(full, name));
  } catch {
    return [];
  }
}

export function touchedEntries(
  entries: EntryRoots[],
  changed: string[],
  options: {
    src?: string;
    repoRoot?: string;
    read?: (file: string) => string | undefined;
    paneStylesheets?: () => string[];
    /** derivedTables() of `changed`, for a test's own pages. */
    tables?: Map<string, string[]>;
  } = {},
): TouchedEntries {
  const src = options.src ?? SRC;
  const repoRoot = options.repoRoot ?? path.resolve(src, "../..");
  const tables = options.tables ?? derivedTables(changed);
  // The tables are build output, absent until gen-strings.mjs runs: an import of one resolves to its path
  // whether or not it was written, so the routing never depends on the checkout's install.
  const tableFiles = new Set([...tables.values()].flat().map((table) => path.join(repoRoot, table)));
  const readFile = options.read ?? readSource;
  const read = (file: string) => readFile(file) ?? (tableFiles.has(file) ? "" : undefined);
  const paneStylesheets = options.paneStylesheets ?? (() => agentPaneStylesheets());
  const ids = entries.map((entry) => entry.id).sort();
  const broad = changed.filter((file) => !tables.has(file) && EVERYTHING.some((pattern) => pattern.test(file)));
  const specific = changed.filter((file) => !broad.includes(file));
  // Each changed file as the file an entry reaches: itself, or for a derived source the tables built from it.
  const changedFull: [string, string][] = specific.flatMap((file) =>
    (tables.get(file) ?? [file]).map((reached): [string, string] => [path.join(repoRoot, reached), file]),
  );
  // What each host's stage module loads for every entry it mounts (the pane's strings, a page's table).
  const hostReach = new Map<string, Set<string>>();
  const hostLoads = (host: string) => {
    if (!hostReach.has(host)) {
      const frame = HOST_FRAMES[host];
      hostReach.set(host, frame ? closure([path.join(src, frame)], read) : new Set());
    }
    return hostReach.get(host)!;
  };
  const reasons: Record<string, string[]> = {};
  const ranks = new Map<string, RankedEntry>();
  const sheets = new Map<string, string[]>();
  const rank = (candidate: RankedEntry) => {
    const best = ranks.get(candidate.id);
    if (!best || candidate.tier < best.tier || (candidate.tier === best.tier && candidate.distance < best.distance))
      ranks.set(candidate.id, candidate);
  };
  for (const entry of entries) {
    if (!sheets.has(entry.host)) sheets.set(entry.host, hostStylesheets(entry.host, src, read, paneStylesheets));
    const covered = entry.covers.flatMap((cover) => coverFiles(cover, src));
    const roots = [entry.file, ...covered];
    const hops = distances(roots, read);
    const own = new Set([
      ...roots,
      ...roots.flatMap((root) => importsOf(root, read)).filter((f) => f.endsWith(".css")),
    ]);
    const folders = new Set(roots.map((root) => path.dirname(root)));
    const entryText = read(entry.file) ?? "";
    const hits = new Set<string>();
    for (const [full, repoPath] of changedFull) {
      const why = (tier: number, reason: RankReason, distance = 0) => {
        hits.add(repoPath);
        rank({ id: entry.id, tier, why: reason, file: repoPath, distance });
      };
      // An asset (an image, a JSON file) counts only where an import or new URL() traces it; a guess by
      // name or folder would place it and skip the full render unplaced.py falls back to.
      const source = SOURCE_EXTENSIONS.includes(path.extname(full));
      if (own.has(full)) why(0, "own");
      else if (source && full.startsWith(`${src}/`) && names(entryText, path.relative(src, full))) why(1, "names");
      else if (hops.has(full)) why(2, "imports", hops.get(full)!);
      else if (source && folders.has(path.dirname(full))) why(3, "same-folder");
      else if (sheets.get(entry.host)!.includes(full)) why(4, "host-stylesheet");
      else if (tableFiles.has(full) && hostLoads(entry.host).has(full)) why(5, "host-table");
    }
    if (hits.size) reasons[entry.id] = [...hits].sort();
  }
  if (broad.length)
    for (const id of ids) {
      reasons[id] = [...new Set([...(reasons[id] ?? []), ...broad.slice(0, 5)])].sort();
      rank({ id, tier: 6, why: "everything", file: broad[0]!, distance: 0 });
    }
  const ranked = [...ranks.values()].sort(
    (a, b) => a.tier - b.tier || a.distance - b.distance || a.id.localeCompare(b.id),
  );
  const derived = specific.filter((file) => tables.has(file)).sort();
  return { all: broad.length > 0, entries: Object.keys(reasons).sort(), reasons, ranked, derived };
}

/** The entries under src/ with the file each one comes from. */
export async function loadEntryRoots(): Promise<EntryRoots[]> {
  return Promise.all(
    galleryFiles().map(async (file) => {
      const { default: entry } = (await import(file)) as { default: { id: string; host: string; covers: string[] } };
      return { id: entry.id, host: entry.host, file, covers: entry.covers };
    }),
  );
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { changed: { type: "string" }, out: { type: "string" } } });
  if (!values.changed) throw new Error("--changed <file with one repo path per line> is required");
  const changed = fs
    .readFileSync(values.changed, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const result = touchedEntries(await loadEntryRoots(), changed);
  const json = `${JSON.stringify(result, null, 2)}\n`;
  if (values.out) fs.writeFileSync(values.out, json);
  else process.stdout.write(json);
  console.error(`gallery: ${result.all ? "every entry" : `${result.entries.length} entries`} touched`);
}
