// Each gallery variant's note ("" for none), as {entry: {variant: note}}, from the entries themselves
// (entries.ts), for scripts/cmux-next/media/whats-new-gallery.py: a note opening "Selected" is the look a file
// picked, one opening "Before:" the look its change replaced. Reading the entries, not the file's text, sees a
// note wherever the variant puts it and never takes a nested prop's for the variant's own (reviews of #39651,
// #39688). It runs the gallery files, so it belongs where they run anyway (the workflow's render job, no secret
// and no write), never in a trusted hook such as prepush-gate.py, which reads their text instead.
//   bun scripts/gallery/notes.ts --out notes.json        every entry
//   bun scripts/gallery/notes.ts src/a/A.gallery.ts ...  only these files' entries, to stdout
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import type { GalleryEntry } from "../../src/gallery/format";
import { loadEntrySources } from "./entries";

export function variantNotes(entries: GalleryEntry[]): Record<string, Record<string, string>> {
  const out: Record<string, Record<string, string>> = {};
  for (const entry of entries) {
    const notes: Record<string, string> = {};
    for (const [variant, state] of Object.entries(entry.variants)) {
      notes[variant] = typeof state.note === "string" ? state.note : "";
    }
    out[entry.id] = notes;
  }
  return out;
}

if (import.meta.main) {
  const { values, positionals } = parseArgs({ options: { out: { type: "string" } }, allowPositionals: true });
  const entries = positionals.length
    ? await Promise.all(
        positionals.map(async (file) => ((await import(path.resolve(file))) as { default: GalleryEntry }).default),
      )
    : (await loadEntrySources()).map(({ entry }) => entry);
  const json = `${JSON.stringify(variantNotes(entries), null, 2)}\n`;
  if (values.out) fs.writeFileSync(values.out, json);
  else process.stdout.write(json);
}
