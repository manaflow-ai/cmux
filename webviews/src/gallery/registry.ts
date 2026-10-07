// Every gallery entry: each `*.gallery.ts(x)` file under src/ exports one by default. The shell
// lists them and a stage frame mounts one; test/gallery-coverage.test.ts reads the same files.
import type { GalleryEntry } from "./format";

const modules = import.meta.glob<GalleryEntry>("../**/*.gallery.{ts,tsx}", { eager: true, import: "default" });

/** The entries, sorted by area and title. */
export const entries: GalleryEntry[] = Object.values(modules).sort(
  (a, b) => a.area.localeCompare(b.area) || a.title.localeCompare(b.title),
);
