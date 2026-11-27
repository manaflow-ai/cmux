// Every gallery entry, read from the `*.gallery.ts(x)` files under src/ without Vite: for the
// coverage test and the matrix manifest generator. (The browser side uses src/gallery/registry.ts,
// an import.meta.glob of the same files.)
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { installGalleryModulesForBun, readEntryIndex } from "../../dev-server/galleryHost";
import type { GalleryEntry } from "../../src/gallery/format";

// A gallery file may import a virtual:cmux-gallery/* module at its top (golden.gallery.ts: the looks): give
// bun the resolver Vite has, before any of them loads.
installGalleryModulesForBun();

export const SRC = fileURLToPath(new URL("../../src", import.meta.url));

export function galleryFiles(dir = SRC): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== "node_modules" && entry.name !== "generated") out.push(...galleryFiles(full));
    } else if (/\.gallery\.tsx?$/.test(entry.name)) out.push(full);
  }
  return out.sort();
}

const matches = (id: string, wanted: readonly string[]) =>
  wanted.some((prefix) => id === prefix || id.startsWith(`${prefix}.`) || id.startsWith(prefix));

/** Select files before importing them so an unrelated broken gallery file cannot block a named entry. */
export function selectGalleryFiles(
  wanted: readonly string[],
  files: readonly string[],
  index: Readonly<Record<string, string>>,
  sourceRoot = SRC,
): string[] {
  if (wanted.length === 0) return [...files];
  const matchedWanted = new Set<string>();
  for (const id of Object.keys(index)) {
    for (const prefix of wanted) {
      if (matches(id, [prefix])) matchedWanted.add(prefix);
    }
  }
  // Computed entry IDs are absent from the source index. Keep the old all-files behavior when any
  // requested ID is unknown so callers still discover those entries through their imports.
  if (matchedWanted.size !== new Set(wanted).size) return [...files];
  const selected = new Set(
    Object.entries(index)
      .filter(([id]) => matches(id, wanted))
      .map(([, source]) => path.resolve(sourceRoot, "..", source)),
  );
  return files.filter((file) => selected.has(file));
}

export async function loadEntries(wanted: readonly string[] = []): Promise<GalleryEntry[]> {
  const modules = await loadEntrySources(wanted);
  return modules
    .map(({ entry }) => entry)
    .sort((a, b) => a.area.localeCompare(b.area) || a.title.localeCompare(b.title));
}

<<<<<<< ours
export async function loadEntrySources(
  wanted: readonly string[] = [],
): Promise<{ entry: GalleryEntry; path: string }[]> {
  const files = selectGalleryFiles(wanted, galleryFiles(), readEntryIndex(SRC));
  const modules = await Promise.all(files.map((file) => import(file) as Promise<{ default: GalleryEntry }>));
  return modules.map((module, index) => ({
    entry: module.default,
    path: `src/${path.relative(SRC, files[index]!).split(path.sep).join("/")}`,
  }));
=======
/** Each entry file's default export and its path. `skipBroken`: a file that fails to load (a syntax error, a throw
 * at its top, no default export) is left out and named on stderr instead of failing every entry, as the browser's
 * registry does (entryStore.ts). whats-new-gallery.yml's render asks for it: on 2026-11-27 one duplicate `const` in an
 * unrelated ClaudeConnectRow.gallery.tsx failed 10 of its runs from 05:14Z to 08:18Z, so four Improved highlights
 * whose pictures were named shipped in nightly 4598742452601 with none. The tests keep the default and fail on it. */
export async function loadEntrySources(
  options: { skipBroken?: boolean; dir?: string } = {},
): Promise<{ entry: GalleryEntry; path: string }[]> {
  const dir = options.dir ?? SRC;
  const files = galleryFiles(dir);
  const loaded = await Promise.allSettled(
    files.map(async (file) => {
      const module = (await import(file)) as { default: GalleryEntry };
      if (options.skipBroken && !module.default) throw new Error("no default export");
      return module.default;
    }),
  );
  const out: { entry: GalleryEntry; path: string }[] = [];
  loaded.forEach((result, index) => {
    const file = `src/${path.relative(dir, files[index]!).split(path.sep).join("/")}`;
    if (result.status === "fulfilled") out.push({ entry: result.value, path: file });
    else if (options.skipBroken) console.error(`gallery: skipped ${file}, which fails to load: ${String(result.reason).split("\n", 1)[0]}`);
    else throw result.reason;
  });
  return out;
>>>>>>> theirs
}
