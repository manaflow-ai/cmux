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
// Every entry of a host is touched by a module its stage (src/gallery/frame/) reaches, since every entry of
// that host loads it ("host-frame"). A string catalog reaches the entries that import the page tables its
// changed keys go into (catalogs.ts, with --base); one whose keys reach no rendered table is `inert`.
//
//   bun scripts/gallery/touched.ts --changed changed.txt [--base REV]   # one repo path per line
//   -> {"all": false, "entries": ["agent-pane.composer"], "reasons": {...}, "ranked": [{"id": ..., "tier": 0, ...}],
//       "inert": []}
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { agentPaneStylesheets } from "../../dev-server/galleryHost";
import { type CatalogRoute, catalogTables, isCatalog, readCheckout, readRevision } from "./catalogs";
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
];

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
  "host-frame",
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
  /** Changed files placed on no entry because no render shows them: a string catalog whose changed keys
   * no page table takes, or whose tables no entry or host frame imports (unplaced.py counts them placed). */
  inert: string[];
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

/**
 * The modules a host's stage loads for every entry it mounts: what its frame module reaches (the agent pane's
 * mountModel and the whole pane under it, the pane's string table, the pages' mock hosts), stylesheets aside.
 * An entry's own imports leave these out, so a change to one of them reached only the entries that happen to
 * import it, while every entry of the host renders it.
 */
export function hostFrameModules(host: string, src: string, read: (file: string) => string | undefined): Set<string> {
  const frame = STAGE_MODULES[host];
  if (!frame) return new Set();
  const full = path.join(src, frame);
  // A stage module that mounts one host loads all it reaches for each of its entries. One that mounts many
  // (pages.ts: every *-page host) loads its static imports for each, and each host's own page through a
  // dynamic import() inside that host's mount function, which is that host's alone.
  const shared = Object.values(STAGE_MODULES).filter((module) => module === frame).length > 1;
  const roots = shared ? [full, ...staticImportsOf(full, read)] : [full];
  const reached = shared ? new Set([full, ...closure(roots.slice(1), read)]) : closure(roots, read);
  return new Set([...reached].filter((file) => !file.endsWith(".css")));
}

/** The stage module (src/gallery/frame/main.ts's `mount`) each host's entries are mounted by. */
const STAGE_MODULES: Record<string, string> = {
  "agent-pane": "gallery/frame/agentPane.ts",
  component: "gallery/frame/component.tsx",
  ...Object.fromEntries(
    [
      "markdown-page",
      "diff-page",
      "apps-page",
      "cloud-page",
      "coderouter-page",
      "changelog-page",
      "icon-picker-page",
      "editor-page",
      "history-page",
      "keybindings-page",
      "settings-page",
      "passwords-page",
    ].map((host) => [host, "gallery/frame/pages.ts"]),
  ),
};

const STATIC_IMPORT = /(?:\bfrom\s*|\bimport\s+)["']([^"']+)["']/g;

/** The relative static imports (`import ... from`, `import "x"`) of one file, resolved. */
function staticImportsOf(file: string, read: (file: string) => string | undefined): string[] {
  const text = read(file) ?? "";
  const out: string[] = [];
  for (const match of text.matchAll(STATIC_IMPORT)) {
    const spec = match[1]!.replace(/\?.*$/, "");
    if (!spec.startsWith(".")) continue;
    const resolved = resolveImport(path.resolve(path.dirname(file), spec), read);
    if (resolved) out.push(resolved);
  }
  return out;
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
    /** Where changed string catalogs land (catalogs.ts); without it every catalog change renders everything. */
    catalogs?: CatalogRoute;
  } = {},
): TouchedEntries {
  const src = options.src ?? SRC;
  const repoRoot = options.repoRoot ?? path.resolve(src, "../..");
  const read = options.read ?? readSource;
  const paneStylesheets = options.paneStylesheets ?? (() => agentPaneStylesheets());
  const ids = entries.map((entry) => entry.id).sort();
  const catalogs = options.catalogs;
  // A catalog with no route (none given, or one no page lists) is global to every page, as before.
  const routedCatalog = (file: string) =>
    !!catalogs &&
    !catalogs.global.includes(file) &&
    (catalogs.inert.includes(file) || Object.values(catalogs.tables).some((from) => from.includes(file)));
  const broad = changed.filter(
    (file) => EVERYTHING.some((pattern) => pattern.test(file)) || (isCatalog(file) && !routedCatalog(file)),
  );
  const specific = changed.filter((file) => !broad.includes(file) && !isCatalog(file));
  // Each changed path, and each page table a changed catalog reaches, with the changed files it stands for.
  const changedFull = new Map<string, string[]>(specific.map((file) => [path.join(repoRoot, file), [file]]));
  for (const [table, from] of Object.entries(catalogs?.tables ?? {})) {
    const reaching = from.filter((file) => changed.includes(file) && !broad.includes(file));
    if (reaching.length)
      changedFull.set(path.join(repoRoot, table), [
        ...(changedFull.get(path.join(repoRoot, table)) ?? []),
        ...reaching,
      ]);
  }
  const reasons: Record<string, string[]> = {};
  const ranks = new Map<string, RankedEntry>();
  const sheets = new Map<string, string[]>();
  const frames = new Map<string, Set<string>>();
  const rank = (candidate: RankedEntry) => {
    const best = ranks.get(candidate.id);
    if (!best || candidate.tier < best.tier || (candidate.tier === best.tier && candidate.distance < best.distance))
      ranks.set(candidate.id, candidate);
  };
  for (const entry of entries) {
    if (!sheets.has(entry.host)) sheets.set(entry.host, hostStylesheets(entry.host, src, read, paneStylesheets));
    if (!frames.has(entry.host)) frames.set(entry.host, hostFrameModules(entry.host, src, read));
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
    for (const [full, repoPaths] of changedFull) {
      const why = (tier: number, reason: RankReason, distance = 0) => {
        for (const repoPath of repoPaths) hits.add(repoPath);
        rank({ id: entry.id, tier, why: reason, file: repoPaths[0]!, distance });
      };
      // An asset (an image, a JSON file) counts only where an import or new URL() traces it; a guess by
      // name or folder would place it and skip the full render unplaced.py falls back to.
      const source = SOURCE_EXTENSIONS.includes(path.extname(full));
      if (own.has(full)) why(0, "own");
      else if (source && full.startsWith(`${src}/`) && names(entryText, path.relative(src, full))) why(1, "names");
      else if (hops.has(full)) why(2, "imports", hops.get(full)!);
      else if (source && folders.has(path.dirname(full))) why(3, "same-folder");
      else if (sheets.get(entry.host)!.includes(full)) why(4, "host-stylesheet");
      else if (frames.get(entry.host)!.has(full)) why(5, "host-frame");
    }
    if (hits.size) reasons[entry.id] = [...hits].sort();
  }
  if (broad.length)
    for (const id of ids) {
      reasons[id] = [...new Set([...(reasons[id] ?? []), ...broad.slice(0, 5)])].sort();
      rank({ id, tier: RANK_REASONS.indexOf("everything"), why: "everything", file: broad[0]!, distance: 0 });
    }
  const ranked = [...ranks.values()].sort(
    (a, b) => a.tier - b.tier || a.distance - b.distance || a.id.localeCompare(b.id),
  );
  // A routed catalog that placed no entry: its keys reach no page table, or no render imports the tables they
  // reach. Like a webviews/src module no entry reaches, it renders nothing.
  const placed = new Set(Object.values(reasons).flat());
  const inert = changed.filter((file) => isCatalog(file) && !broad.includes(file) && !placed.has(file)).sort();
  return { all: broad.length > 0, entries: Object.keys(reasons).sort(), reasons, ranked, inert };
}

/**
 * Every file touchedEntries can place on some entry (its imports, its covers, its folder, its host's frame
 * modules and stylesheets), and the paths it renders everything for: what route-check.ts holds the
 * gallery build's own module list against.
 */
export function reachableFiles(
  entries: EntryRoots[],
  options: { src?: string; read?: (file: string) => string | undefined; paneStylesheets?: () => string[] } = {},
): { reachable: { has: (file: string) => boolean }; broad: (repoPath: string) => boolean } {
  const src = options.src ?? SRC;
  const read = options.read ?? readSource;
  const paneStylesheets = options.paneStylesheets ?? (() => agentPaneStylesheets());
  const files = new Set<string>();
  const folders = new Set<string>();
  for (const host of new Set(entries.map((entry) => entry.host))) {
    for (const sheet of hostStylesheets(host, src, read, paneStylesheets)) files.add(sheet);
    for (const module of hostFrameModules(host, src, read)) files.add(module);
  }
  for (const entry of entries) {
    const roots = [entry.file, ...entry.covers.flatMap((cover) => coverFiles(cover, src))];
    for (const file of closure(roots, read)) files.add(file);
    for (const root of roots) folders.add(path.dirname(root));
  }
  const reachable = {
    has: (file: string) =>
      files.has(file) || (SOURCE_EXTENSIONS.includes(path.extname(file)) && folders.has(path.dirname(file))),
  };
  return { reachable, broad: (repoPath) => EVERYTHING.some((pattern) => pattern.test(repoPath)) };
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
  const { values } = parseArgs({
    options: { changed: { type: "string" }, out: { type: "string" }, base: { type: "string" } },
  });
  if (!values.changed) throw new Error("--changed <file with one repo path per line> is required");
  const changed = fs
    .readFileSync(values.changed, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  // --base REV: the revision the change is compared with, so a changed string catalog renders only the
  // entries whose page tables take a changed key. Without it every catalog change renders everything.
  const repoRoot = path.resolve(SRC, "../..");
  const catalogs = values.base
    ? catalogTables(changed, readCheckout(repoRoot), readRevision(repoRoot, values.base))
    : undefined;
  const result = touchedEntries(await loadEntryRoots(), changed, { catalogs });
  const json = `${JSON.stringify(result, null, 2)}\n`;
  if (values.out) fs.writeFileSync(values.out, json);
  else process.stdout.write(json);
  console.error(`gallery: ${result.all ? "every entry" : `${result.entries.length} entries`} touched`);
}
