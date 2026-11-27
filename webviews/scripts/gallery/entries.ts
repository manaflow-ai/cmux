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

export async function loadEntrySources(
  wanted: readonly string[] = [],
): Promise<{ entry: GalleryEntry; path: string }[]> {
  const files = selectGalleryFiles(wanted, galleryFiles(), readEntryIndex(SRC));
  const modules = await Promise.all(files.map((file) => import(file) as Promise<{ default: GalleryEntry }>));
  return modules.map((module, index) => ({
    entry: module.default,
    path: `src/${path.relative(SRC, files[index]!).split(path.sep).join("/")}`,
  }));
}
