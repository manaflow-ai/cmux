#!/usr/bin/env bun
// Which gallery entries a change touches, for the per-PR gallery (.github/workflows/gallery-pr.yml):
// an entry is touched when a changed file is its own `*.gallery.ts`, or is reachable through
// relative imports from that file or from one of its `covers`. Following imports catches what
// `covers` leaves out (a hook, a shared helper). A stylesheet is global to the page that loads it,
// so a changed stylesheet of an entry's host (the agent pane's shipped CSS, a page's imports)
// touches every entry of that host. A change to the gallery itself, the build config or the
// lockfile touches every entry.
//
//   bun scripts/gallery/touched.ts --changed changed.txt            # one repo path per line
//   -> {"all": false, "entries": ["agent-pane.composer"], "reasons": {"agent-pane.composer": ["..."]}}
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { agentPaneStylesheets } from "../../dev-server/galleryHost";
import { galleryFiles, SRC } from "./entries";

/** Repo paths that re-render every entry when they change. */
const EVERYTHING = [
  /^webviews\/src\/gallery\//,
  /^webviews\/scripts\/gallery\//,
  /^webviews\/dev-server\/galleryHost\.ts$/,
  /^scripts\/cmux-next\/build-agent-pane-web\.sh$/,
  /^webviews\/vite\.config(\.gallery)?\.ts$/,
  /^webviews\/package\.json$/,
  /^bun\.lock$/,
  /^scripts\/gallery-matrix\//,
];

const SOURCE_EXTENSIONS = [".ts", ".tsx", ".js", ".mjs", ".css"];
const IMPORT = /(?:\bfrom\s*|\bimport\s*\(?\s*)["']([^"']+)["']/g;

export type TouchedEntries = { all: boolean; entries: string[]; reasons: Record<string, string[]> };
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
  } = {},
): TouchedEntries {
  const src = options.src ?? SRC;
  const repoRoot = options.repoRoot ?? path.resolve(src, "../..");
  const read = options.read ?? readSource;
  const paneStylesheets = options.paneStylesheets ?? (() => agentPaneStylesheets());
  const ids = entries.map((entry) => entry.id).sort();
  const broad = changed.filter((file) => EVERYTHING.some((pattern) => pattern.test(file)));
  if (broad.length)
    return { all: true, entries: ids, reasons: Object.fromEntries(ids.map((id) => [id, broad.slice(0, 5)])) };
  const changedFull = new Map(changed.map((file) => [path.join(repoRoot, file), file]));
  const reasons: Record<string, string[]> = {};
  const sheets = new Map<string, string[]>();
  for (const entry of entries) {
    if (!sheets.has(entry.host)) sheets.set(entry.host, hostStylesheets(entry.host, src, read, paneStylesheets));
    const roots = [entry.file, ...entry.covers.flatMap((cover) => coverFiles(cover, src))];
    const reached = new Set([...closure(roots, read), ...sheets.get(entry.host)!]);
    const hits = [...reached].flatMap((file) => changedFull.get(file) ?? []);
    if (hits.length) reasons[entry.id] = hits.sort();
  }
  return { all: false, entries: Object.keys(reasons).sort(), reasons };
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
