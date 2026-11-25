// gallery health's base replay builds only the red entries (CMUX_GALLERY_ENTRIES, galleryEntrySubset): the whole
// gallery's 3,224 modules took ~80 s of every judged shard to replay a handful of states (2026-11-11). Only the
// registry glob's own imports become empty modules, so an entry another module imports is still built for it.
import { describe, expect, test } from "bun:test";
import path from "node:path";
import { entrySubsetFiles, galleryEntrySubset, readEntryIndex } from "../dev-server/galleryHost";

const webviews = path.resolve(import.meta.dir, "..");
const registry = path.join(webviews, "src/gallery/registry.ts");
const index = readEntryIndex();
const file = (id: string) => path.join(webviews, index[id]!);

type Hooks = {
  resolveId: (this: unknown, source: string, importer: string | undefined, options: object) => Promise<unknown>;
  load: (id: string) => string | null;
};

function hooks(entries: string): Hooks {
  const plugin = galleryEntrySubset(entries) as unknown as Hooks;
  return plugin;
}

// What the bundler's own resolution answers: the file the import names, relative to its importer.
const context = {
  resolve: async (source: string, importer: string) => ({ id: path.resolve(path.dirname(importer), source) }),
};
const relative = (id: string) => path.relative(path.dirname(registry), file(id));

describe("gallery entry subset", () => {
  test("names the file of each entry asked for, and nothing for an entry the tree lacks", () => {
    const files = entrySubsetFiles(["agent-pane.transcript", "agent-pane.long-report", "no-such.entry"]);
    expect(files).toEqual(new Set([file("agent-pane.transcript"), file("agent-pane.long-report")]));
  });

  test("an entry that embeds the mock app builds every entry, which the mock app loads by id", () => {
    expect(index["font-study.screen"]).toBeDefined();
    expect(entrySubsetFiles(["agent-pane.transcript", "font-study.screen"])).toBeUndefined();
  });

  test("the registry's import of an entry left out loads as an empty module; a kept one resolves as usual", async () => {
    const { resolveId, load } = hooks("agent-pane.transcript");
    const kept = await resolveId.call(context, relative("agent-pane.transcript"), registry, {});
    expect(kept).toEqual({ id: file("agent-pane.transcript") });
    const skipped = (await resolveId.call(context, relative("agent-pane.long-report"), registry, {})) as string;
    expect(skipped.startsWith("\0")).toBe(true);
    expect(load(skipped)).toBe("export default undefined;");
    expect(load(file("agent-pane.transcript"))).toBeNull();
  });

  test("an entry file another module imports is still built for that importer", async () => {
    const { resolveId } = hooks("agent-pane.transcript");
    const importer = path.join(webviews, "src/agent-session/acpmux/cloudErgonomics/states.tsx");
    expect(await resolveId.call(context, "../CloudStartView.gallery.tsx", importer, {})).toBeNull();
  });

  test("unset, empty or a mock-app entry: every entry is built", async () => {
    for (const entries of ["", " , ", "font-study.screen"]) {
      const { resolveId } = hooks(entries);
      expect(await resolveId.call(context, relative("agent-pane.long-report"), registry, {})).toBeNull();
    }
  });
});
