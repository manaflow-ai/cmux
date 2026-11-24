// A save of a source file re-sends a Tailwind stylesheet only when the save adds a class that
// stylesheet compiles to new CSS. @tailwindcss/vite registers every file its scanner reads as a
// watch file of the stylesheet (`addWatchFile`), so Vite gives each scanned .tsx a file-only
// module whose importer is the stylesheet: every save of a .tsx hot-updated the whole stylesheet
// too, regenerated it, and the page's Fast Refresh of the component waited for that fetch (the
// Vite client applies one update's modules together) and then restyled the whole document.
//
// Here each Tailwind stylesheet gets a twin compiler and scanner, seeded with the same sources
// the plugin scans. On a save, the scanner returns the candidates it has not seen before; when the
// twin compiler's CSS does not change with them, the plugin's own CSS could not change either
// (Tailwind's candidate set only grows in dev), so the file-only module is left out of the update.
// Vite has already invalidated the stylesheet's cached transform (`onFileChange` reaches the
// stylesheet through that module), so the next request for it, a reload or the next save with a
// new class, still regenerates it.
import fs from "node:fs";
import path from "node:path";
import { compile } from "@tailwindcss/node";
import { Scanner } from "@tailwindcss/oxide";
import type { EnvironmentModuleNode, Plugin } from "vite-plus";

const CSS = /\.(?:css|pcss|postcss)(?:\?.*)?$/;
const TAILWIND_ENTRY = /@import\s+["']tailwindcss|@tailwind\b|@import\s+["']tailwindcss\//;

type Twin = { scanner: Scanner; compiler: Awaited<ReturnType<typeof compile>>; css: string };

/// A file whose text the twin scanner reads by extension (Tailwind's own extractor per kind).
function extensionOf(file: string): string {
  return path.extname(file).slice(1) || "html";
}

/** The twin of one Tailwind stylesheet: its compiler and a scanner over the plugin's sources. */
export async function twinOf(stylesheet: string, root: string): Promise<Twin> {
  const compiler = await compile(fs.readFileSync(stylesheet, "utf8"), {
    base: path.dirname(stylesheet),
    onDependency: () => {},
  });
  // As @tailwindcss/vite builds its scanner: no root is the Vite root, `none` scans nothing.
  const sources = (
    compiler.root === "none"
      ? []
      : compiler.root === null
        ? [{ base: root, pattern: "**/*", negated: false }]
        : [{ ...compiler.root, negated: false }]
  ).concat(compiler.sources);
  const scanner = new Scanner({ sources });
  return { scanner, compiler, css: compiler.build(scanner.scan()) };
}

/** Whether `content` (a save of a file of kind `extension`) adds CSS to the twin's stylesheet. */
export function addsCss(twin: Twin, content: string, extension: string): boolean {
  const fresh = twin.scanner.scanFiles([{ content, extension }]);
  if (!fresh.length) return false;
  const css = twin.compiler.build(fresh);
  if (css === twin.css) return false;
  twin.css = css;
  return true;
}

export function tailwindOnNewClasses(): Plugin {
  // By stylesheet file. A pending twin is still being made: saves meanwhile update as before.
  const twins = new Map<string, Twin | Promise<Twin | null> | null>();
  let root = process.cwd();
  const twin = (stylesheet: string): Twin | null => {
    const known = twins.get(stylesheet);
    if (known === undefined) {
      const making = twinOf(stylesheet, root).then(
        (made) => (twins.get(stylesheet) === making && twins.set(stylesheet, made), made),
        () => (twins.get(stylesheet) === making && twins.set(stylesheet, null), null),
      );
      twins.set(stylesheet, making);
      return null;
    }
    return known instanceof Promise ? null : known;
  };
  return {
    name: "cmux-tailwind-on-new-classes",
    apply: "serve",
    configResolved(config) {
      root = config.root;
    },
    // A Tailwind stylesheet's twin is made after the page first asks for it, off the save path.
    transform: {
      order: "post",
      handler(_code, id) {
        if (this.environment?.name !== "client" || !CSS.test(id)) return;
        const file = id.split("?")[0];
        if (twins.has(file) || !fs.existsSync(file) || !TAILWIND_ENTRY.test(fs.readFileSync(file, "utf8"))) return;
        setImmediate(() => twin(file));
      },
    },
    async hotUpdate({ file, modules, read }) {
      if (this.environment.name !== "client") return;
      // A stylesheet or its imports changed: every twin is remade on its next use.
      if (CSS.test(file)) {
        twins.clear();
        return;
      }
      const dropped = new Set<EnvironmentModuleNode>();
      let content: string | undefined;
      for (const mod of modules) {
        // Only the file-only module Vite's CSS plugin made for a stylesheet's watch file.
        if (mod.id || mod.type !== "asset" || !mod.importers.size) continue;
        const importers = [...mod.importers];
        if (!importers.every((importer) => importer.file && CSS.test(importer.file))) continue;
        let unchanged = true;
        for (const importer of importers) {
          const ready = twin(importer.file!);
          if (!ready) {
            unchanged = false;
            continue;
          }
          content ??= await read();
          // Every twin sees the save, so each one's candidate set keeps up with the plugin's.
          if (addsCss(ready, content, extensionOf(file))) unchanged = false;
        }
        if (unchanged) dropped.add(mod);
      }
      return dropped.size ? modules.filter((mod) => !dropped.has(mod)) : undefined;
    },
  };
}
