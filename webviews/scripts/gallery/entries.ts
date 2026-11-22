// Every gallery entry, read from the `*.gallery.ts(x)` files under src/ without Vite: for the
// coverage test and the matrix manifest generator. (The browser side uses src/gallery/registry.ts,
// an import.meta.glob of the same files.)
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { GalleryEntry } from "../../src/gallery/format";

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

export async function loadEntries(): Promise<GalleryEntry[]> {
  const modules = await Promise.all(galleryFiles().map((file) => import(file) as Promise<{ default: GalleryEntry }>));
  return modules
    .map((module) => module.default)
    .sort((a, b) => a.area.localeCompare(b.area) || a.title.localeCompare(b.title));
}
