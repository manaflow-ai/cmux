// The webviews dev server: `bun run dev` (vite.config.ts) serves every surface from one port in a
// plain browser, with hot reload. Every plugin here is `apply: "serve"`, so `vp build` and the
// shipped bundles never see it. Surfaces, each a path:
//   /                 an index of the surfaces below
//   /diff/            the diff viewer (`cmux diff`) against the real cmux-diff-sidecar
//   /markdown?file=   the markdown editor (markdown-page.html, src/pages/markdown) on a repo file
//   /markdown/viewer?file=  the classic markdown viewer shell (Resources/markdown-viewer/shell.html)
//   /agent-pane/      the agent pane (src/agent-session/acpmux/index.html; prototype.html beside it)
//   /history/ /apps/ /cloud/ /keybindings/  React pages (src/pages/<page>/index.html); `?mock` uses the page's in-memory provider
// scripts/agent-pane/dev-slot.sh runs one per slot next to a standalone acpmux daemon.
//
// Env: CMUX_WEBVIEWS_DEV_PORT (default 4200). Diff: CMUX_DIFF_SIDECAR (else the newest one in a
// built app), CMUX_DIFF_DEV_CMUX, CMUX_DIFF_DEV_REPO (the repo above webviews/), CMUX_DIFF_DEV_BASE
// (HEAD~5). Markdown: CMUX_MARKDOWN_DEV_ROOT (the repo above webviews/, writable),
// CMUX_MARKDOWN_DEV_READONLY_ROOTS (colon-separated folders whose files open read only),
// CMUX_MARKDOWN_DEV_FILE.
import { execFileSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import type { ServerResponse } from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Plugin, ViteDevServer } from "vite-plus";
import {
  dependencyCacheName,
  isDependencyCacheRequest,
  isLoopbackHost,
  payloadFor,
  readBody,
  resolveResource,
  rpcRequestStatus,
} from "./diffHost";
import { diffLanguagesDirectory, readDiffLanguagePack } from "./diffLanguages";
import {
  PAGE_LIBS,
  SHELL_LIBS,
  SHELL_PLACEHOLDERS,
  fillShell,
  markdownAsset,
  markdownFiles,
  readMarkdown,
  saveMarkdown,
  splitStyles,
} from "./markdownHost";

const webviewsRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const repoRoot = path.join(webviewsRoot, "..");

export const DEV_SERVER_PORT = Number(process.env.CMUX_WEBVIEWS_DEV_PORT) || 4200;

/// All dev-server plugins, for vite.config.ts.
export function cmuxDevServer(): Plugin[] {
  return [devServerShell(), agentPaneHost(), pagesHost(), diffHost(), markdownHost()];
}

function send(response: ServerResponse, status: number, type: string, body: string): void {
  response.statusCode = status;
  response.setHeader("Content-Type", type);
  response.setHeader("Cache-Control", "no-store");
  response.end(body);
}

function redirect(response: ServerResponse, location: string): void {
  response.statusCode = 302;
  response.setHeader("Location", location);
  response.end();
}

function errorText(error: unknown): string {
  return error instanceof Error ? (error.stack ?? error.message) : String(error);
}

const indexPage = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>cmux webviews (dev)</title>
<script>
  // A cmux-next pointed at this server's root (CMUX_NEXT_AGENT_PANE_DEV_URL) wants the pane.
  if (window.webkit?.messageHandlers?.agentSession) location.replace("/agent-pane/" + location.search + location.hash);
</script>
<style>body{font:14px -apple-system,system-ui,sans-serif;margin:32px;line-height:1.6}code{font-size:12px}</style>
</head><body>
<h1>cmux webviews (dev)</h1>
<ul>
<li><a href="/diff/">/diff/</a>: diff viewer, <code>?source=branch&amp;base=HEAD~5</code>, <code>?source=unstaged|staged</code>, <code>&amp;layout=unified</code></li>
<li><a href="/markdown">/markdown</a>: markdown editor, <code>?file=&lt;path&gt;</code>; <a href="/markdown/viewer">/markdown/viewer</a>: the classic viewer shell</li>
<li><a href="/history/?mock">/history/?mock</a>: History page against the in-page mock provider</li>
<li><a href="/apps/?mock">/apps/?mock</a>: App Store page against the in-page mock provider (<code>#/discover?layout=list|split</code>, <code>#/installed</code>)</li>
<li><a href="/cloud/?mock">/cloud/?mock</a>: Cloud page against the in-page mock provider (<code>&amp;layout=cards</code> for the cards layout)</li>
<li><a href="/keybindings/?mock">/keybindings/?mock</a>: Keyboard Shortcuts page against the in-page mock provider</li>
<li><a href="/agent-pane/?mock">/agent-pane/?mock</a>: agent pane against the in-page mock daemon (<code>dev-slot.sh</code> prints a real-daemon URL); <a href="/agent-pane/prototype.html?mock">prototype.html</a></li>
</ul>
</body></html>`;

const devEntries = [
  "src/diff/dev.ts",
  "src/diff-worker.ts",
  "src/agent-session/acpmux/dev.tsx",
  "src/agent-session/acpmux/prototype/dev.tsx",
  "src/markdown-viewer/devHost.ts",
  "src/pages/markdown/devBridge.ts",
  "src/pages/markdown/main.tsx",
];

/// The index page, dev React and the dependency cache.
function devServerShell(): Plugin {
  return {
    name: "cmux-dev-server",
    apply: "serve",
    config(config) {
      // vite.config.ts pins NODE_ENV to production for the shipped bundle; dev keeps React's
      // development build, which Fast Refresh needs.
      if (config.define) delete config.define["process.env.NODE_ENV"];
      return {
        // One dependency cache per server. A cache shared with another server on the same
        // node_modules (vite.config.acpmux-pane.mjs, another slot) is re-optimized under it, and
        // open pages then fail to load modules and requests mid-load.
        cacheDir: `node_modules/${dependencyCacheName(config.server?.port ?? DEV_SERVER_PORT)}`,
        // Every surface's entry, so the first scan finds all dependencies instead of a page
        // discovering one late and triggering an optimizer reload.
        optimizeDeps: { entries: devEntries },
      };
    },
    configureServer(server) {
      const cacheName = dependencyCacheName(server.config.server.port ?? DEV_SERVER_PORT);
      server.middlewares.use((request, response, next) => {
        const pathname = new URL(request.url ?? "/", "http://localhost").pathname;
        if (pathname === "/" || pathname === "/index.html") return send(response, 200, "text/html", indexPage);
        // Vite serves optimized dependencies as `immutable` for a year, keyed by a `?v=` hash
        // of the lockfile and config only. When the set of optimized dependencies changes (a
        // source file starts importing one directly), the hash stays and the chunks inside are
        // renamed, so a long-lived WebView (the cmux browser pane) keeps old modules that import
        // chunks that no longer exist: "Importing a module script failed", then "Load failed".
        // Revalidating them by ETag costs a 304 per module and never serves a stale graph.
        if (isDependencyCacheRequest(pathname, cacheName)) {
          const setHeader = response.setHeader.bind(response);
          response.setHeader = (name, value) =>
            setHeader(name, name.toLowerCase() === "cache-control" ? "no-cache" : value);
        }
        next();
      });
    },
  };
}

/// /agent-pane/<page>.html serves src/agent-session/acpmux/<page>.html (index.html for the
/// directory), a second HTML entry beside the diff viewer's. The page itself runs the fragment
/// handshake (devHost.ts) in Swift's place. Mirrors vite.config.acpmux-pane.mjs, which still
/// serves the pane alone at its root.
function agentPaneHost(): Plugin {
  const paneDir = path.join(webviewsRoot, "src/agent-session/acpmux");
  const paneURL = "/src/agent-session/acpmux";
  const sharedStyles = path.join(webviewsRoot, "src/agent-session/shared/styles.css");
  // The bundle drops the shared stylesheet's Tailwind @import (only its variables and rules
  // ship). The pane imports it through this `.pcss` id instead, which Tailwind's plugin skips
  // and Vite still serves as CSS with hot reload.
  const paneStyles = `${sharedStyles}.agent-pane.pcss`;
  return {
    name: "cmux-dev-agent-pane",
    apply: "serve",
    enforce: "pre",
    resolveId(source, importer) {
      // Hot updates request the module again with a `?t=` query, which the id keeps.
      const [bare, query] = source.split("?", 2);
      if (bare === paneStyles || bare === `/${path.relative(webviewsRoot, paneStyles)}`) {
        return query ? `${paneStyles}?${query}` : paneStyles;
      }
      if (!importer?.startsWith(`${paneDir}/`) || !source.endsWith("shared/styles.css")) return null;
      return path.resolve(path.dirname(importer.split("?")[0]), source) === sharedStyles ? paneStyles : null;
    },
    load(id) {
      return id.split("?")[0] === paneStyles ? fs.readFileSync(sharedStyles, "utf8") : null;
    },
    transform(code, id) {
      if (id.split("?")[0] !== paneStyles) return null;
      return { code: code.replace(/^@import .*$/gm, ""), map: null };
    },
    handleHotUpdate({ file, server, modules }) {
      // The `.pcss` module has no file of its own; a save of the real stylesheet updates it.
      const paneModule = file === sharedStyles ? server.moduleGraph.getModuleById(paneStyles) : undefined;
      return paneModule ? [...modules, paneModule] : undefined;
    },
    configureServer(server) {
      server.middlewares.use(async (request, response, next) => {
        const url = new URL(request.url ?? "/", "http://localhost");
        if (url.pathname === "/agent-pane") return redirect(response, `/agent-pane/${url.search}`);
        const page = url.pathname.match(/^\/agent-pane\/([A-Za-z0-9-]*\.html)?$/);
        if (!page) return next();
        const name = page[1] ?? "index.html";
        let html: string;
        try {
          html = fs.readFileSync(path.join(paneDir, name), "utf8");
        } catch {
          return send(response, 404, "text/plain", "no such agent pane page");
        }
        try {
          // The page's relative script sources are relative to the pane directory, not /agent-pane/.
          html = html.replace(/(\bsrc=")\.\//g, `$1${paneURL}/`);
          html = await server.transformIndexHtml(`${paneURL}/${name}`, html, request.originalUrl);
          send(response, 200, "text/html; charset=utf-8", html);
        } catch (error) {
          next(error);
        }
      });
    },
  };
}

/// /<page>/ serves src/pages/<page>/index.html for the React pages (plans/cmux-next/react-pages.md).
/// The page boots its own client: the app bridge when present, else the mock provider with `?mock`.
const DEV_PAGES = ["history", "apps", "cloud", "keybindings"];

function pagesHost(): Plugin {
  return {
    name: "cmux-dev-pages",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use(async (request, response, next) => {
        const url = new URL(request.url ?? "/", "http://localhost");
        const match = url.pathname.match(/^\/([a-z-]+)\/?$/);
        const page = match?.[1];
        if (!page || !DEV_PAGES.includes(page)) return next();
        if (!url.pathname.endsWith("/")) return redirect(response, `/${page}/${url.search}`);
        const pageURL = `/src/pages/${page}`;
        try {
          let html = fs.readFileSync(path.join(webviewsRoot, "src/pages", page, "index.html"), "utf8");
          html = html.replace(/(\bsrc=")\.\//g, `$1${pageURL}/`);
          html = await server.transformIndexHtml(`${pageURL}/index.html`, html, request.originalUrl);
          send(response, 200, "text/html; charset=utf-8", html);
        } catch (error) {
          next(error);
        }
      });
    },
  };
}

function subdirs(parent: string, pattern: RegExp, suffix: string): string[] {
  try {
    return fs
      .readdirSync(parent)
      .filter((entry) => pattern.test(entry))
      .map((entry) => path.join(parent, entry, suffix));
  } catch {
    return [];
  }
}

/// The newest `name` bundled in a built app (/tmp/panedev-*-app/*.app or a tagged DerivedData build).
function newestAppBinary(name: string): string | undefined {
  const appDirs = [
    ...subdirs("/tmp", /^panedev-.*-app$/, ""),
    ...subdirs(path.join(os.homedir(), "Library/Developer/Xcode/DerivedData"), /^cmux-/, "Build/Products/Debug"),
  ];
  let best: { path: string; mtime: number } | undefined;
  for (const dir of appDirs) {
    for (const bin of subdirs(dir, /\.app$/, "Contents/Resources/bin")) {
      const candidate = path.join(bin, name);
      try {
        const mtime = fs.statSync(candidate).mtimeMs;
        if (!best || mtime > best.mtime) best = { path: candidate, mtime };
      } catch {}
    }
  }
  return best?.path;
}

type SidecarHost = { sidecar: string; cmux: string; root: string; token: string; protocolVersion: number };

/// The diff viewer: /diff/ is index.html with src/diff/dev.ts as its entry. The server plays
/// the two app roles the viewer needs: the `cmuxDiff` WebKit handler (POST /__cmux-diff/rpc pipes
/// one DiffRequest into `cmux-diff-sidecar rpc`) and the `cmux-diff-viewer://` scheme (patch
/// resources the sidecar names, from its manifest, under /__cmux-diff/resource/<token>/<path>).
/// Like the CLI, it writes a `.branch-session-dev.json` that authorizes one repo for a fresh token.
function diffHost(): Plugin {
  const diffSurface = path.join(webviewsRoot, "src/surfaces/diffSurface.tsx");
  const repo = fs.realpathSync(process.env.CMUX_DIFF_DEV_REPO || repoRoot);
  const defaultBase = process.env.CMUX_DIFF_DEV_BASE || "HEAD~5";
  const inlineStylesStub = "\0cmux-diff-dev-inline-styles";
  let host: SidecarHost | undefined;
  let cleanup = () => {};

  // Started on the first diff request, so the other surfaces run without a sidecar.
  function sidecarHost(): SidecarHost {
    if (host) return host;
    const sidecar = process.env.CMUX_DIFF_SIDECAR || newestAppBinary("cmux-diff-sidecar");
    if (!sidecar) throw new Error("no cmux-diff-sidecar: set CMUX_DIFF_SIDECAR or build a tagged app");
    // Only branch-picker requests (branchList, an unset base) shell out to cmux; git does the rest.
    const cmux = process.env.CMUX_DIFF_DEV_CMUX || path.join(path.dirname(sidecar), "cmux");
    const handshake = JSON.parse(execFileSync(sidecar, ["handshake"], { encoding: "utf8" }));
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-diff-dev-"));
    fs.chmodSync(root, 0o700);
    cleanup = () => fs.rmSync(root, { recursive: true, force: true });
    process.once("exit", cleanup);
    const token = randomBytes(24).toString("hex");
    fs.writeFileSync(
      path.join(root, ".branch-session-dev.json"),
      JSON.stringify({ token, groupID: "dev", allowedRepoRoots: [repo] }),
      { mode: 0o600 },
    );
    // The sidecar appends each session's patch to the token's manifest and refuses to create one;
    // the CLI seeds it with the viewer page, so seed it with a placeholder page entry.
    const page = path.join(root, "viewer.html");
    fs.writeFileSync(page, "<!doctype html>\n", { mode: 0o600 });
    fs.writeFileSync(
      path.join(root, `.manifest-${token}.json`),
      JSON.stringify({
        token,
        files: [{ request_path: "/viewer.html", file_path: page, mime_type: "text/html", remote_url: null }],
      }),
      { mode: 0o600 },
    );
    host = { sidecar, cmux, root, token, protocolVersion: handshake.result.value.protocolVersion };
    return host;
  }

  function runSidecar(active: SidecarHost, body: Buffer): Promise<string> {
    return new Promise((resolve, reject) => {
      const child = spawn(active.sidecar, ["rpc", "--root", active.root, "--cmux", active.cmux], {
        stdio: ["pipe", "pipe", "pipe"],
      });
      const out: Buffer[] = [];
      const err: Buffer[] = [];
      child.stdout.on("data", (chunk: Buffer) => out.push(chunk));
      child.stderr.on("data", (chunk: Buffer) => err.push(chunk));
      child.on("error", reject);
      child.on("close", (code) => {
        if (code === 0) resolve(Buffer.concat(out).toString("utf8"));
        else reject(new Error(`cmux-diff-sidecar exited ${code}: ${Buffer.concat(err).toString("utf8")}`));
      });
      child.stdin.end(body);
    });
  }

  async function diffPage(server: ViteDevServer): Promise<string> {
    const html = fs
      .readFileSync(path.join(webviewsRoot, "index.html"), "utf8")
      .replace('src="/src/main.tsx"', 'src="/src/diff/dev.ts"');
    return server.transformIndexHtml("/index.html", html);
  }

  return {
    name: "cmux-dev-diff",
    apply: "serve",
    enforce: "pre",
    resolveId(source, importer) {
      // The shipped surface installs styles.css from a `?inline` string; dev.ts imports it as a
      // stylesheet instead so it hot-updates, and the inline copy becomes empty.
      if (source === "../styles.css?inline" && importer?.split("?")[0] === diffSurface) return inlineStylesStub;
      return null;
    },
    load(id) {
      return id === inlineStylesStub ? 'export default "";' : null;
    },
    configureServer(server) {
      const port = () => server.config.server.port ?? DEV_SERVER_PORT;
      server.httpServer?.on("close", () => cleanup());
      // The languages folder hot-applies like the app's watcher: open pages get the new pack.
      // fs.watch, not Vite's watcher, which does not report this folder outside the project. A
      // folder created after the server started applies on the next page load.
      const languagesDirectory = diffLanguagesDirectory();
      try {
        const watcher = fs.watch(languagesDirectory, { recursive: true }, () => {
          const data = readDiffLanguagePack(languagesDirectory);
          server.ws.send({ type: "custom", event: "cmux-diff-languages", data });
        });
        server.httpServer?.on("close", () => watcher.close());
      } catch {
        // No languages folder.
      }
      server.middlewares.use(async (request, response, next) => {
        const url = new URL(request.url ?? "/", "http://localhost");
        if (url.pathname === "/diff" || url.pathname === "/diff/") {
          try {
            return send(response, 200, "text/html; charset=utf-8", await diffPage(server));
          } catch (error) {
            return next(error);
          }
        }
        // worker-pool.ts spawns `./diff-worker.mjs` next to itself, which the build emits; in dev
        // that sibling is the TypeScript entry.
        if (url.pathname === "/src/diff-worker.mjs") {
          request.url = `/src/diff-worker.ts${url.search}`;
          return next();
        }
        if (!url.pathname.startsWith("/__cmux-diff/")) return next();
        if (!isLoopbackHost(request.headers.host, port())) return send(response, 403, "text/plain", "");
        try {
          if (url.pathname === "/__cmux-diff/config") {
            const config = payloadFor(sidecarHost(), repo, defaultBase, url.searchParams);
            (config.payload as Record<string, unknown>).languages = readDiffLanguagePack(diffLanguagesDirectory());
            return send(response, 200, "application/json", JSON.stringify(config));
          }
          if (url.pathname === "/__cmux-diff/rpc") {
            const refused = rpcRequestStatus(request, port());
            if (refused) return send(response, refused, "text/plain", "");
            const reply = await runSidecar(sidecarHost(), await readBody(request));
            // The sidecar names patches by the app scheme; point them at this server instead.
            const body = reply.replaceAll("cmux-diff-viewer://", "/__cmux-diff/resource/");
            return send(response, 200, "application/json", body);
          }
          if (url.pathname.startsWith("/__cmux-diff/resource/") && host) {
            // Like the app's cmux-diff-viewer:// handler: only manifest-listed files inside the root.
            const resource = resolveResource(host.root, url.pathname.slice("/__cmux-diff/resource/".length));
            if (!resource) return send(response, 404, "text/plain", "");
            response.setHeader("Content-Type", resource.contentType);
            response.setHeader("Cache-Control", "no-store");
            return void fs.createReadStream(resource.file).pipe(response);
          }
          return send(response, 404, "text/plain", "");
        } catch (error) {
          server.config.logger.error(`cmux diff dev: ${errorText(error)}`);
          return send(response, 500, "text/plain", error instanceof Error ? error.message : String(error));
        }
      });
    },
  };
}

/// The markdown editor and the classic viewer. /markdown serves markdown-page.html (the editor,
/// src/pages/markdown) with src/pages/markdown/devBridge.ts first, which installs a stand-in for the
/// app's cmuxPage bridge: its calls arrive as POST /__cmux-markdown/op and this server implements
/// the host ops (host.ts) on files below the root, saves refused on a hash conflict; images come
/// from /__cmux-markdown/asset/<file>/<path>, diagram libraries from /__cmux-markdown/page-lib/.
/// /markdown/viewer fills shell.html's {{placeholders}} from the same assets
/// MarkdownViewerAssets.shellHTML uses and adds src/markdown-viewer/devHost.ts, which plays the
/// Swift host (render calls and the `cmuxLib` handler). Edits to a shell <style> block or a bundled
/// stylesheet replace that style in place; markdown saves re-render in place; script edits reload.
function markdownHost(): Plugin {
  const assetsDir = fs.realpathSync(path.join(webviewsRoot, "../Resources/markdown-viewer"));
  const shellPath = path.join(assetsDir, "shell.html");
  const files = markdownFiles(
    process.env.CMUX_MARKDOWN_DEV_ROOT || repoRoot,
    process.env.CMUX_MARKDOWN_DEV_FILE || path.join(webviewsRoot, "src/agent-session/acpmux/README.md"),
    (process.env.CMUX_MARKDOWN_DEV_READONLY_ROOTS ?? "").split(":").filter(Boolean),
  );
  const watchedAssets = new Set([
    shellPath,
    ...Object.values(SHELL_PLACEHOLDERS).map((name) => path.join(assetsDir, name)),
  ]);
  const watchedFiles = new Set<string>();
  const readAsset = (name: string) => fs.readFileSync(path.join(assetsDir, name), "utf8");
  const shellHTML = () => fillShell(readAsset("shell.html"), readAsset);
  let last = { styles: [] as string[], skeleton: "" };
  const watch = (server: ViteDevServer, file: string) => {
    if (watchedFiles.has(file)) return;
    watchedFiles.add(file);
    server.watcher.add(file);
  };

  type OpReply = { status: number; body: unknown };
  const runOp = (server: ViteDevServer, file: string, op: string, params: Record<string, unknown>): OpReply => {
    const pageError = (status: number, code: string, message: string, details?: unknown) => ({
      status,
      body: { code, message, details },
    });
    if (op === "cmux.markdown.config" || op === "cmux.markdown.read") {
      const content = readMarkdown(file);
      if (!content)
        return op === "cmux.markdown.read"
          ? { status: 200, body: { deleted: true } }
          : pageError(404, "cmux.markdown.not_found", file);
      watch(server, file);
      if (op === "cmux.markdown.read") return { status: 200, body: { text: content.text, hash: content.hash } };
      return {
        status: 200,
        body: {
          path: file,
          text: content.text,
          hash: content.hash,
          readOnly: !files.writable(file) || !content.utf8,
          assetBase: `/__cmux-markdown/asset/${encodeURIComponent(file)}/`,
          libBase: "/__cmux-markdown/page-lib/",
        },
      };
    }
    if (op === "cmux.markdown.save") {
      if (params.path !== file || typeof params.text !== "string")
        return pageError(400, "cmux.protocol.invalid_params", "save");
      const baseHash = typeof params.baseHash === "string" ? params.baseHash : null;
      const outcome = saveMarkdown(file, params.text, baseHash, files.writable(file));
      if (outcome.ok) return { status: 200, body: { hash: outcome.hash } };
      return pageError(409, outcome.code, outcome.code, "details" in outcome ? outcome.details : undefined);
    }
    if (op === "cmux.markdown.openLink") {
      // The dev stand-in for the app: a markdown file below the root opens in this page, anything
      // else the browser opens.
      const href = typeof params.href === "string" ? params.href : "";
      if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return { status: 200, body: { url: href } };
      const target = files.link(file, href);
      return { status: 200, body: target ? { navigate: `/markdown?file=${encodeURIComponent(target)}` } : {} };
    }
    return pageError(404, "cmux.protocol.unknown_op", op);
  };

  return {
    name: "cmux-dev-markdown",
    apply: "serve",
    configureServer(server) {
      const port = () => server.config.server.port ?? DEV_SERVER_PORT;
      server.watcher.add([...watchedAssets]);
      server.watcher.on("unlink", (file) => {
        if (watchedFiles.has(file)) server.ws.send({ type: "custom", event: "cmux-markdown:content", data: { file } });
      });
      last = splitStyles(shellHTML());
      server.middlewares.use(async (request, response, next) => {
        const url = new URL(request.url ?? "/", "http://localhost");
        if (url.pathname === "/markdown" || url.pathname === "/markdown/") {
          const file = files.file(url.searchParams.get("file") ?? "");
          if (!file) return send(response, 404, "text/plain", `not a markdown file under ${files.root}`);
          if (!url.searchParams.has("file") || url.pathname.endsWith("/")) {
            return redirect(response, `/markdown?file=${encodeURIComponent(file)}`);
          }
          try {
            let html = fs.readFileSync(path.join(webviewsRoot, "markdown-page.html"), "utf8");
            html = html
              .replace('src="./src/', 'src="/src/')
              .replace("<body>", '<body>\n    <script type="module" src="/src/pages/markdown/devBridge.ts"></script>');
            html = await server.transformIndexHtml("/markdown-page.html", html, request.originalUrl);
            return send(response, 200, "text/html; charset=utf-8", html);
          } catch (error) {
            return next(error);
          }
        }
        if (url.pathname === "/markdown/viewer") {
          const file = files.file(url.searchParams.get("file") ?? "");
          if (!file) return send(response, 404, "text/plain", `not a markdown file under ${files.root}`);
          if (!url.searchParams.has("file"))
            return redirect(response, `/markdown/viewer?file=${encodeURIComponent(file)}`);
          const html = shellHTML().replace(
            "</body>",
            '<script type="module" src="/@vite/client"></script>\n<script type="module" src="/src/markdown-viewer/devHost.ts"></script>\n</body>',
          );
          return send(response, 200, "text/html; charset=utf-8", html);
        }
        if (url.pathname === "/__cmux-markdown/op") {
          const refused = rpcRequestStatus(request, port());
          if (refused) return send(response, refused, "text/plain", "");
          try {
            const body = JSON.parse((await readBody(request)).toString("utf8")) as {
              file?: string;
              op?: string;
              params?: Record<string, unknown>;
            };
            const file = files.file(body.file ?? "");
            if (!file)
              return send(response, 404, "application/json", JSON.stringify({ code: "cmux.markdown.not_found" }));
            const reply = runOp(server, file, String(body.op), body.params ?? {});
            return send(response, reply.status, "application/json", JSON.stringify(reply.body));
          } catch (error) {
            server.config.logger.error(`cmux markdown dev: ${errorText(error)}`);
            return send(
              response,
              500,
              "application/json",
              JSON.stringify({ code: "cmux.page.failed", message: String(error) }),
            );
          }
        }
        const asset = url.pathname.match(/^\/__cmux-markdown\/asset\/([^/]+)\/(.+)$/);
        if (asset) {
          const file = files.file(decodeURIComponent(asset[1]));
          const resolved = file ? markdownAsset(file, decodeURIComponent(asset[2])) : undefined;
          if (!resolved) return send(response, 404, "text/plain", "");
          response.setHeader("Content-Type", resolved.contentType);
          response.setHeader("Cache-Control", "no-store");
          return void fs.createReadStream(resolved.file).pipe(response);
        }
        const pageLib = url.pathname.match(/^\/__cmux-markdown\/page-lib\/([a-z-]+)\.js$/)?.[1];
        if (pageLib) {
          if (!Object.hasOwn(PAGE_LIBS, pageLib)) return send(response, 404, "text/plain", "unknown lib");
          return send(response, 200, "text/javascript", PAGE_LIBS[pageLib].map(readAsset).join("\n;"));
        }
        if (url.pathname === "/__cmux-markdown/content") {
          const file = files.file(url.searchParams.get("file") ?? "");
          if (!file) return send(response, 404, "text/plain", "not found");
          watch(server, file);
          return send(response, 200, "text/markdown; charset=utf-8", fs.readFileSync(file, "utf8"));
        }
        if (url.pathname === "/__cmux-markdown/resolve") {
          const resolved = files.link(url.searchParams.get("from") ?? "", url.searchParams.get("path"));
          return send(response, 200, "application/json", JSON.stringify({ exists: !!resolved, path: resolved ?? "" }));
        }
        const lib = url.pathname.match(/^\/__cmux-markdown\/lib\/([a-z-]+)\.js$/)?.[1];
        if (lib) {
          if (!Object.hasOwn(SHELL_LIBS, lib)) return send(response, 404, "text/plain", "unknown lib");
          return send(response, 200, "text/javascript", SHELL_LIBS[lib].map(readAsset).join("\n;"));
        }
        next();
      });
    },
    handleHotUpdate({ file, server }) {
      if (watchedFiles.has(file)) {
        server.ws.send({ type: "custom", event: "cmux-markdown:content", data: { file } });
        return [];
      }
      if (!watchedAssets.has(file)) return;
      const next = splitStyles(shellHTML());
      if (next.skeleton === last.skeleton) {
        server.ws.send({ type: "custom", event: "cmux-markdown:styles", data: next.styles });
      } else {
        server.ws.send({ type: "full-reload" });
      }
      last = next;
      return [];
    },
  };
}
