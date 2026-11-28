// The live gallery's dev-server half (vite.config.gallery-dev.ts): what keeps one broken entry from
// breaking the page, and what the shell shows about the checkout it serves.
//
// Entry saves. A save of an entry file (`*.gallery.ts(x)`), or of a module only entry files import
// (fixtures), does NOT go through Vite's HMR propagation: entry files accept no update, so it would
// climb to the shell's root and reload the whole page. The plugin invalidates that chain itself and
// sends `cmux-gallery:entry` with the entry files; the shell's store loads each one again on its own
// (registry.ts), so a fixed file recovers in place. Saves anywhere else take Vite's normal path
// (React Fast Refresh in the shell and the stages).
//
// Compile errors. Vite sends a failed transform to every open page as a full-page overlay. The plugin
// sorts each error by who imports the failing module: a module the shell imports (outside entry
// files) keeps the overlay; one reached only through entry files is shown on those entries' error
// cards; anything else (component and page code the stages load) is shown inside the stages
// (frame/liveErrors.ts). Both go out as `cmux-gallery:status` and are listed in the shell's banner.
//
// Status. `<base>__cmux_gallery/status` answers the checkout's commit and the current errors; the
// plugin pushes `cmux-gallery:status` again when either changes (it reads HEAD every few seconds,
// so a fast-forward of the checkout shows at once).
import { execFile } from "node:child_process";
import path from "node:path";
import type { Plugin } from "vite-plus";
import { readRevision, type Revision } from "./galleryHost";

/** The part of a Vite module node the scope walk reads. */
export type ScopeNode = { file: string | null; importers: Set<ScopeNode> };

export type Scope<N extends ScopeNode> = {
  /** Entry modules reached (the walk stops at each). */
  entries: N[];
  /** Every module walked from the start up to (and with) the entries. */
  chain: N[];
  /** Reached the shell's root without passing an entry file. */
  shell: boolean;
  /** Reached another root (a stage frame, another page) without passing an entry file. */
  other: boolean;
};

/** Walks importers up from `start`, stopping at entry files, and says which roots it reached. */
export function scopeOf<N extends ScopeNode>(
  start: Iterable<N>,
  isEntry: (file: string) => boolean,
  isShellRoot: (file: string) => boolean,
): Scope<N> {
  const scope: Scope<N> = { entries: [], chain: [], shell: false, other: false };
  const seen = new Set<N>();
  const queue = [...start];
  while (queue.length) {
    const node = queue.shift()!;
    if (seen.has(node)) continue;
    seen.add(node);
    scope.chain.push(node);
    if (node.file && isEntry(node.file)) {
      scope.entries.push(node);
      continue;
    }
    if (node.file && isShellRoot(node.file)) scope.shell = true;
    else if (node.importers.size === 0) scope.other = true;
    for (const importer of node.importers) queue.push(importer as N);
  }
  return scope;
}

/**
 * The failing module of a prepared Vite error: its id, else its location's file, else the first
 * path under webviews/ in its message (the React Compiler's Babel errors name the file only there).
 */
export function errorFile(
  error: { id?: string; loc?: { file?: string }; message?: string; stack?: string },
  root: string,
): string {
  const named = error.id ?? error.loc?.file;
  if (named) return named.split("?")[0]!;
  const text = `${error.message ?? ""}\n${error.stack ?? ""}`;
  const at = text.indexOf(`${root}/`);
  return at < 0 ? "" : /^[^\s:?()'"]+/.exec(text.slice(at))![0];
}

export type ErrorKind = "shell" | "entry" | "stage";

/** Where a failing module's error belongs (see the file comment). */
export function errorKind(scope: Scope<ScopeNode>): ErrorKind {
  if (scope.shell) return "shell";
  return scope.entries.length > 0 && !scope.other ? "entry" : "stage";
}

type LiveError = {
  file: string;
  kind: "entry" | "stage";
  entries: string[];
  message: string;
  frame?: string;
  stack?: string;
  plugin?: string;
  id?: string;
  loc?: { file?: string; line: number; column: number };
};

type PreparedError = Omit<LiveError, "file" | "kind" | "entries">;

export function galleryLive({ webviewsRoot, repoRoot }: { webviewsRoot: string; repoRoot: string }): Plugin {
  const srcDir = path.join(webviewsRoot, "src");
  const shellRoot = path.join(webviewsRoot, "src/gallery/shell/main.tsx");
  const isEntry = (file: string) => file.startsWith(`${srcDir}/`) && /\.gallery\.tsx?$/.test(file);
  const isShellRoot = (file: string) => file === shellRoot;
  const rel = (file: string) => path.relative(webviewsRoot, file);
  const errors = new Map<string, LiveError>();
  let revision: Revision = readRevision(repoRoot);
  let broadcast = () => {};
  const status = () => ({ ...revision, errors: [...errors.values()] });

  return {
    name: "cmux-gallery-live",
    apply: "serve",
    configureServer(server) {
      const client = server.environments.client;
      const send = client.hot.send.bind(client.hot) as (...args: unknown[]) => void;
      broadcast = () => send({ type: "custom", event: "cmux-gallery:status", data: status() });
      const scopeOfFile = (file: string) =>
        scopeOf((client.moduleGraph.getModulesByFile(file) ?? new Set()) as Set<ScopeNode>, isEntry, isShellRoot);

      // Reroute compile errors that are not the shell's (see the file comment).
      client.hot.send = ((...args: unknown[]) => {
        const payload = args[0] as { type?: string; err?: PreparedError } | undefined;
        if (payload && typeof payload === "object" && payload.type === "error" && payload.err) {
          const file = errorFile(payload.err, webviewsRoot);
          if (file && path.isAbsolute(file)) {
            const scope = scopeOfFile(file);
            // A module the graph does not know yet: an entry file is still an entry's; else the shell's.
            const kind: ErrorKind = scope.chain.length === 0 ? (isEntry(file) ? "entry" : "shell") : errorKind(scope);
            if (kind !== "shell") {
              const entries = scope.chain.length === 0 ? [rel(file)] : scope.entries.map((node) => rel(node.file!));
              const { message, frame, stack, plugin, id, loc } = payload.err;
              errors.set(rel(file), { file: rel(file), kind, entries, message, frame, stack, plugin, id, loc });
              server.config.logger.info(`[gallery] ${kind} compile error kept out of the overlay: ${rel(file)}`);
              broadcast();
              return;
            }
          }
        }
        send(...args);
      }) as typeof client.hot.send;

      server.middlewares.use((request, response, next) => {
        const pathname = (request.url ?? "").split("?")[0];
        if (pathname !== `${server.config.base}__cmux_gallery/status` && pathname !== "/__cmux_gallery/status")
          return next();
        response.statusCode = 200;
        response.setHeader("Content-Type", "application/json");
        response.setHeader("Cache-Control", "no-store");
        response.end(JSON.stringify(status()));
      });

      // HEAD moves when the host fast-forwards the checkout; Vite sees the files, this sees the commit.
      const timer = setInterval(() => {
        execFile("git", ["-C", repoRoot, "rev-parse", "HEAD"], (error, stdout) => {
          if (error || stdout.trim() === revision.sha) return;
          revision = readRevision(repoRoot);
          broadcast();
        });
      }, 3000);
      timer.unref();
      server.httpServer?.once("close", () => clearInterval(timer));
    },
    hotUpdate({ type, file, modules, timestamp }) {
      // A new or deleted entry file changes the glob: Vite reloads the page for it.
      if (this.environment.name !== "client" || type !== "update") return;
      // A save clears the file's error; a load that still fails records it again.
      const cleared = errors.delete(rel(file));
      const scope = scopeOf(modules as Iterable<ScopeNode>, isEntry, isShellRoot);
      const entryFiles = isEntry(file) ? [rel(file)] : scope.entries.map((node) => rel(node.file!));
      const notify = () =>
        this.environment.hot.send({
          type: "custom",
          event: "cmux-gallery:entry",
          data: { files: entryFiles, timestamp },
        });
      if (cleared) broadcast();
      if (isEntry(file) || (entryFiles.length > 0 && !scope.shell && !scope.other)) {
        // Only entries import it: new module URLs for the chain, then the shell loads those entries again.
        const seen = new Set<never>();
        for (const node of scope.chain)
          this.environment.moduleGraph.invalidateModule(node as never, seen, timestamp, true);
        notify();
        return [];
      }
      if (entryFiles.length > 0) notify();
      return undefined;
    },
  };
}
