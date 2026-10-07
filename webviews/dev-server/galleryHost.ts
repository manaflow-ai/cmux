// The gallery (src/gallery): its dev route and the build inputs it shares with the app.
//   /gallery/            the shell: every entry and state, with the controls
//   /gallery/frame.html  one stage: one state of one entry under the controls (the shell's iframes,
//                        the matrix runner's screenshots)
// Virtual modules, for `bun run dev` and the static build (vite.config.gallery.ts) alike:
//   virtual:cmux-gallery/themes            every Ghostty theme the app ships (Resources/ghostty/themes)
//   virtual:cmux-gallery/web-theme         WebTheme.bootstrapScript, the script the app injects at
//                                          document start in every cmux web view (WebTheme.swift)
//   virtual:cmux-gallery/agent-pane.css    the agent pane's shipped stylesheet, the files and the
//                                          order scripts/cmux-next/build-agent-pane-web.sh inlines
//   virtual:cmux-gallery/metrics           the chrome metrics (MetricTunables.swift: sidebar width,
//                                          tab strip height, ...) per density, for window mode
//   virtual:cmux-gallery/fixtures          every shared fixture JSON (schemas/gallery/fixtures.json
//                                          roots, the Swift packages' Fixtures folders) by repo path
//   virtual:cmux-gallery/revision          the checkout's commit (sha, subject, commit time, branch),
//                                          read when the module loads; the live server pushes newer
//                                          ones (galleryLive.ts)
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Plugin } from "vite-plus";
import { parseGhosttyTheme, type GhosttyTheme } from "../src/gallery/theme/ghostty";

const webviewsRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const repoRoot = path.join(webviewsRoot, "..");
export const THEMES_DIR = path.join(repoRoot, "Resources/ghostty/themes");
const WEB_THEME_SWIFT = path.join(repoRoot, "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Windows/WebTheme.swift");
const PANE_BUILD_SCRIPT = path.join(repoRoot, "scripts/cmux-next/build-agent-pane-web.sh");
const SESSION = path.join(webviewsRoot, "src/agent-session");
const galleryDir = path.join(webviewsRoot, "src/gallery");

const FIXTURE_INDEX = path.join(repoRoot, "schemas/gallery/fixtures.json");
const FIXTURES_ID = "virtual:cmux-gallery/fixtures";
const METRICS_ID = "virtual:cmux-gallery/metrics";
const METRICS_SWIFT = path.join(
  repoRoot,
  "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Tunables/MetricTunables.swift",
);
const THEMES_ID = "virtual:cmux-gallery/themes";
const WEB_THEME_ID = "virtual:cmux-gallery/web-theme";
const REVISION_ID = "virtual:cmux-gallery/revision";
const PANE_CSS_ID = "virtual:cmux-gallery/agent-pane.css";
// The CSS id is a path under the gallery (no file there), so Vite's CSS pipeline takes it.
const PANE_CSS_PATH = path.join(galleryDir, "agent-pane.virtual.css");

/** Every shipped theme, sorted by name; files that name no colors are skipped. */
export function readShippedThemes(dir = THEMES_DIR): GhosttyTheme[] {
  return fs
    .readdirSync(dir)
    .filter((name) => !name.startsWith("."))
    .sort((a, b) => a.localeCompare(b, "en"))
    .map((name) => parseGhosttyTheme(name, fs.readFileSync(path.join(dir, name), "utf8")))
    .filter((theme): theme is GhosttyTheme => theme !== null);
}

/** The shared fixture roots (repo-relative), from schemas/gallery/fixtures.json. */
export function fixtureRoots(index = FIXTURE_INDEX): string[] {
  const roots = (JSON.parse(fs.readFileSync(index, "utf8")) as { roots?: unknown }).roots;
  if (!Array.isArray(roots) || !roots.every((root) => typeof root === "string"))
    throw new Error(`gallery: ${index} must list "roots" as strings`);
  return roots;
}

/** Every fixture JSON under the shared roots, by repo-relative path. */
export function readSharedFixtures(): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const walk = (dir: string) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".json"))
        out[path.relative(repoRoot, full)] = JSON.parse(fs.readFileSync(full, "utf8"));
    }
  };
  for (const root of fixtureRoots()) walk(path.join(repoRoot, root));
  return out;
}

/** Every MetricTunable's default per density: `{ sidebarWidth: { compact: 208, comfortable: 240 }, ... }`. */
export function readChromeMetrics(file = METRICS_SWIFT): Record<string, { compact: number; comfortable: number }> {
  const swift = fs.readFileSync(file, "utf8");
  const out: Record<string, { compact: number; comfortable: number }> = {};
  for (const match of swift.matchAll(
    /MetricTunable\.make\(\s*"(\w+)"[^)]*?compact:\s*([\d.]+),\s*comfortable:\s*([\d.]+)/g,
  ))
    out[match[1]!] = { compact: Number(match[2]), comfortable: Number(match[3]) };
  for (const name of ["sidebarWidth", "titlebarHeight", "tabStripHeight", "tabHeight", "columnGap"])
    if (!out[name]) throw new Error(`gallery: no ${name} in ${file}; update readChromeMetrics`);
  return out;
}

/** WebTheme.bootstrapScript's JavaScript: the Swift multi-line literal, without its indentation. */
export function readWebThemeBootstrap(file = WEB_THEME_SWIFT): string {
  const swift = fs.readFileSync(file, "utf8");
  const match = /static let bootstrapScript = """\n([\s\S]*?)\n([ \t]*)"""/.exec(swift);
  if (!match) throw new Error(`gallery: no bootstrapScript literal in ${file}`);
  const indent = match[2]!;
  const script = match[1]!
    .split("\n")
    .map((line) => (line.startsWith(indent) ? line.slice(indent.length) : line.trimStart()))
    .join("\n");
  // The gallery runs it as is; a Swift interpolation or escape would make it differ from the app's.
  if (/\\\(|\\[nt"\\]/.test(script)) throw new Error("gallery: bootstrapScript has Swift escapes; extend the reader");
  return script;
}

/**
 * The pane's stylesheets in shipped order: desktop.css, the shared stylesheet without its Tailwind
 * @import lines, then every `$SRC/...css` file the build script concatenates. (KaTeX's stylesheet
 * loads beside it; the shipped copy only inlines its fonts.)
 */
export function agentPaneStylesheets(script = PANE_BUILD_SCRIPT): string[] {
  const text = fs.readFileSync(script, "utf8");
  const files = [...text.matchAll(/"\$SRC\/([^"$]+\.css)"/g)].map((match) => path.join(SESSION, match[1]!));
  if (!files.some((file) => file.endsWith("shared/styles.css")))
    throw new Error("gallery: build-agent-pane-web.sh no longer names shared/styles.css; update agentPaneStylesheets");
  return [path.join(webviewsRoot, "src/pages/shared/desktop.css"), ...files];
}

export type Revision = { sha: string; subject: string; committedAt: number; branch: string };

/** The checkout's HEAD: sha, subject, commit time (unix seconds) and branch (empty when detached). */
export function readRevision(root = repoRoot): Revision {
  try {
    const [sha = "", committedAt = "0", subject = ""] = execFileSync(
      "git",
      ["-C", root, "log", "-1", "--format=%H%x00%ct%x00%s", "HEAD"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    )
      .trim()
      .split("\0");
    // CMUX_GALLERY_BRANCH: the live host's checkouts are detached on the branch they follow.
    let branch = process.env.CMUX_GALLERY_BRANCH ?? "";
    if (!branch)
      branch = execFileSync("git", ["-C", root, "branch", "--show-current"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
    return { sha, subject, committedAt: Number(committedAt) || 0, branch };
  } catch {
    return { sha: "unknown", subject: "", committedAt: 0, branch: "" };
  }
}

function agentPaneCSS(): string {
  const inlineRelativeImports = (file: string, css: string, seen = new Set<string>()): string =>
    css.replace(/^@import\s+["']([^"']+)["'];\s*$/gm, (statement, specifier: string) => {
      if (!specifier.startsWith(".")) return statement;
      const imported = path.resolve(path.dirname(file), specifier);
      if (seen.has(imported)) return "";
      seen.add(imported);
      if (!fs.existsSync(imported)) return statement;
      return inlineRelativeImports(imported, fs.readFileSync(imported, "utf8"), seen);
    });

  return agentPaneStylesheets()
    .map((file) => {
      const css = fs.readFileSync(file, "utf8");
      const body = file.endsWith("shared/styles.css")
        ? css.replace(/^@import .*$/gm, "")
        : inlineRelativeImports(file, css);
      return `/* ${path.relative(webviewsRoot, file)} */\n${body}`;
    })
    .join("\n");
}

/** The virtual modules, for the dev server and the static build. */
export function galleryModules(): Plugin {
  return {
    name: "cmux-gallery-modules",
    resolveId(source) {
      if ([THEMES_ID, WEB_THEME_ID, FIXTURES_ID, METRICS_ID, REVISION_ID].includes(source)) return `\0${source}`;
      if (source === PANE_CSS_ID) return PANE_CSS_PATH;
      return null;
    },
    load(id) {
      if (id === `\0${THEMES_ID}`) return `export default ${JSON.stringify(readShippedThemes())};`;
      if (id === `\0${METRICS_ID}`) return `export default ${JSON.stringify(readChromeMetrics())};`;
      if (id === `\0${FIXTURES_ID}`) return `export default ${JSON.stringify(readSharedFixtures())};`;
      if (id === `\0${WEB_THEME_ID}`) return `export default ${JSON.stringify(readWebThemeBootstrap())};`;
      if (id === `\0${REVISION_ID}`) return `export default ${JSON.stringify(readRevision())};`;
      if (id.split("?")[0] === PANE_CSS_PATH) return agentPaneCSS();
      return null;
    },
    configureServer(server) {
      // The sources live partly outside webviews/ (the themes, WebTheme.swift, the build script),
      // where Vite does not watch: watch them, and reload the module built from a changed one.
      const roots = fixtureRoots().map((root) => path.join(repoRoot, root));
      server.watcher.add([THEMES_DIR, WEB_THEME_SWIFT, PANE_BUILD_SCRIPT, FIXTURE_INDEX, METRICS_SWIFT, ...roots]);
      server.watcher.on("all", (_event, file) => {
        const fixture = file === FIXTURE_INDEX || roots.some((root) => file.startsWith(`${root}/`));
        const id = fixture
          ? `\0${FIXTURES_ID}`
          : file === METRICS_SWIFT
            ? `\0${METRICS_ID}`
            : file.startsWith(`${THEMES_DIR}/`)
              ? `\0${THEMES_ID}`
              : file === WEB_THEME_SWIFT
                ? `\0${WEB_THEME_ID}`
                : file === PANE_BUILD_SCRIPT
                  ? PANE_CSS_PATH
                  : undefined;
        const module = id ? server.moduleGraph.getModuleById(id) : undefined;
        if (!module) return;
        server.moduleGraph.invalidateModule(module);
        server.ws.send({ type: "full-reload" });
      });
    },
    handleHotUpdate({ file, server, modules }) {
      // A save of any pane stylesheet updates the combined sheet in place.
      if (!agentPaneStylesheets().includes(file)) return undefined;
      const combined = server.moduleGraph.getModuleById(PANE_CSS_PATH);
      if (!combined) return undefined;
      server.moduleGraph.invalidateModule(combined);
      return [...modules, combined];
    },
  };
}

/**
 * The shell and a stage in the dev server: `<mount>` and `<mount>frame.html`. `bun run dev` mounts
 * them at /gallery/; the live gallery (vite.config.gallery-dev.ts) at its base, `/live/` or
 * `/wt/<name>/`, where the base is also every module URL's prefix.
 */
export function galleryHost({ mount = "/gallery/" }: { mount?: string } = {}): Plugin {
  const escaped = mount.replace(/[.*+?^$()|[\]{}\\]/g, "\\$&");
  const page = new RegExp(`^${escaped}(index\\.html|frame\\.html)?$`);
  return {
    name: "cmux-dev-gallery",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use(async (request, response, next) => {
        const url = new URL(request.url ?? "/", "http://localhost");
        if (url.pathname === mount.slice(0, -1)) {
          response.statusCode = 302;
          response.setHeader("Location", `${mount}${url.search}`);
          return response.end();
        }
        const match = page.exec(url.pathname);
        if (!match) return next();
        const name = match[1] ?? "index.html";
        try {
          let html = fs.readFileSync(path.join(galleryDir, name), "utf8");
          // The page's relative script sources are relative to src/gallery, not the mount. (Vite
          // puts its base before a root-absolute URL.)
          html = html.replace(/(\bsrc=")\.\//g, "$1/src/gallery/");
          html = await server.transformIndexHtml(`/src/gallery/${name}`, html, request.originalUrl);
          response.statusCode = 200;
          response.setHeader("Content-Type", "text/html; charset=utf-8");
          response.setHeader("Cache-Control", "no-store");
          response.end(html);
        } catch (error) {
          next(error);
        }
      });
    },
  };
}
