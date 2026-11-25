// A save of a source file re-sends a Tailwind stylesheet only when the save adds a class that
// stylesheet compiles to new CSS. @tailwindcss/vite registers every file its scanner reads as a
// watch file of the stylesheet (`addWatchFile`), so Vite gives each scanned .tsx a file-only
// module whose importer is the stylesheet: every save of a .tsx hot-updated the whole stylesheet
// too, regenerated it, and the page's Fast Refresh of the component waited for that fetch (the
// Vite client applies one update's modules together) and then restyled the whole document.
//
// Here each Tailwind stylesheet gets a twin compiler and scanner (dev-server/tailwindTwin.mjs, in
// a worker), seeded with the same sources the plugin scans. On a save, the scanner returns the
// candidates it has not seen before; when the twin compiler's CSS does not change with them, the
// plugin's own CSS could not change either (Tailwind's candidate set only grows in dev), so the
// file-only module is left out of the update. Vite has already invalidated the stylesheet's
// cached transform (`onFileChange` reaches the stylesheet through that module), so the next
// request for it, a reload or the next save with a new class, still regenerates it.
import fs from "node:fs";
import path from "node:path";
import { Worker } from "node:worker_threads";
import type { EnvironmentModuleNode, Plugin } from "vite-plus";

const CSS = /\.(?:css|pcss|postcss)(?:\?.*)?$/;
const TAILWIND_ENTRY = /@import\s+["']tailwindcss|@tailwind\b/;
const TWIN = new URL("./tailwindTwin.mjs", import.meta.url);

/// Whether a stylesheet is a Tailwind entry, itself or through a relative `@import` (the Settings
/// page's page.css imports styles.css).
function importsTailwind(file: string, seen = new Set<string>()): boolean {
  if (seen.has(file) || !fs.existsSync(file)) return false;
  seen.add(file);
  const text = fs.readFileSync(file, "utf8");
  if (TAILWIND_ENTRY.test(text)) return true;
  for (const [, spec] of text.matchAll(/@import\s+["'](\.{1,2}\/[^"']+\.css)["']/g))
    if (importsTailwind(path.resolve(path.dirname(file), spec!), seen)) return true;
  return false;
}

/// The text kind the twin's scanner reads a saved file as (Tailwind's own extractor per kind).
function extensionOf(file: string): string {
  return path.extname(file).slice(1) || "html";
}

/** One stylesheet's twin in its worker; `adds` is undefined until the twin is made. */
class TwinWorker {
  private worker: Worker;
  private ready = false;
  private next = 0;
  private answers = new Map<number, (adds: boolean) => void>();
  constructor(stylesheet: string, root: string, onGone: () => void) {
    this.worker = new Worker(TWIN, { workerData: { cmuxTailwindTwin: true, stylesheet, root } });
    this.worker.unref();
    this.worker.on("message", (message: { ready?: boolean; id?: number; adds?: boolean }) => {
      if (message.ready === false) {
        this.close();
        onGone();
        return;
      }
      if (message.ready) this.ready = true;
      if (message.id !== undefined) {
        this.answers.get(message.id)?.(message.adds !== false);
        this.answers.delete(message.id);
      }
    });
    // A twin that fails says nothing about the stylesheet: every save updates it as before.
    const gone = () => {
      for (const answer of this.answers.values()) answer(true);
      this.answers.clear();
      onGone();
    };
    this.worker.on("error", gone);
    this.worker.on("exit", gone);
  }
  adds(content: string, extension: string): Promise<boolean> | undefined {
    if (!this.ready) return undefined;
    const id = this.next++;
    this.worker.postMessage({ id, content, extension });
    return new Promise((resolve) => this.answers.set(id, resolve));
  }
  close() {
    void this.worker.terminate();
  }
}

export function tailwindOnNewClasses(): Plugin {
  const twins = new Map<string, TwinWorker>();
  let root = process.cwd();
  const twin = (stylesheet: string): TwinWorker => {
    let made = twins.get(stylesheet);
    if (!made) {
      const worker: TwinWorker = new TwinWorker(stylesheet, root, () => {
        if (twins.get(stylesheet) === worker) twins.delete(stylesheet);
      });
      made = worker;
      twins.set(stylesheet, made);
    }
    return made;
  };
  const closeAll = () => {
    for (const made of twins.values()) made.close();
    twins.clear();
  };
  return {
    name: "cmux-tailwind-on-new-classes",
    apply: "serve",
    configResolved(config) {
      root = config.root;
    },
    configureServer(server) {
      server.httpServer?.once("close", closeAll);
    },
    // A Tailwind stylesheet's twin is made when the page first asks for it, off the save path.
    transform: {
      order: "post",
      handler(_code, id) {
        if (this.environment?.name !== "client" || !CSS.test(id)) return;
        const file = id.split("?")[0]!;
        if (!twins.has(file) && importsTailwind(file)) twin(file);
      },
    },
    async hotUpdate({ file, modules, read }) {
      if (this.environment.name !== "client") return;
      // A stylesheet or its imports changed: every twin is remade on its next use.
      if (CSS.test(file)) {
        closeAll();
        return;
      }
      const dropped = new Set<EnvironmentModuleNode>();
      let content: string | undefined;
      for (const mod of modules) {
        // Only the file-only module Vite's CSS plugin made for a stylesheet's watch file.
        if (mod.id || mod.type !== "asset" || !mod.importers.size) continue;
        const importers = [...mod.importers];
        if (!importers.every((importer) => importer.file && CSS.test(importer.file))) continue;
        content ??= await read();
        // Every ready twin sees the save, so each one's candidate set keeps up with the plugin's.
        const answers = importers.map((importer) => twin(importer.file!).adds(content!, extensionOf(file)));
        const adds = await Promise.all(answers.map((answer) => answer ?? Promise.resolve(true)));
        if (!adds.includes(true)) dropped.add(mod);
      }
      return dropped.size ? modules.filter((mod) => !dropped.has(mod)) : undefined;
    },
  };
}
