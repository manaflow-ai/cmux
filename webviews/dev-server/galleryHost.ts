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

const THEMES_ID = "virtual:cmux-gallery/themes";
const WEB_THEME_ID = "virtual:cmux-gallery/web-theme";
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

function agentPaneCSS(): string {
  return agentPaneStylesheets()
    .map((file) => {
      const css = fs.readFileSync(file, "utf8");
      const body = file.endsWith("shared/styles.css") ? css.replace(/^@import .*$/gm, "") : css;
      return `/* ${path.relative(webviewsRoot, file)} */\n${body}`;
    })
    .join("\n");
}

/** The virtual modules, for the dev server and the static build. */
export function galleryModules(): Plugin {
  return {
    name: "cmux-gallery-modules",
    resolveId(source) {
      if (source === THEMES_ID || source === WEB_THEME_ID) return `\0${source}`;
      if (source === PANE_CSS_ID) return PANE_CSS_PATH;
      return null;
    },
    load(id) {
      if (id === `\0${THEMES_ID}`) return `export default ${JSON.stringify(readShippedThemes())};`;
      if (id === `\0${WEB_THEME_ID}`) return `export default ${JSON.stringify(readWebThemeBootstrap())};`;
      if (id.split("?")[0] === PANE_CSS_PATH) return agentPaneCSS();
      return null;
    },
    configureServer(server) {
      // The sources live partly outside webviews/ (the themes, WebTheme.swift, the build script),
      // where Vite does not watch: watch them, and reload the module built from a changed one.
      server.watcher.add([THEMES_DIR, WEB_THEME_SWIFT, PANE_BUILD_SCRIPT]);
      server.watcher.on("all", (_event, file) => {
        const id = file.startsWith(`${THEMES_DIR}/`)
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

/** /gallery/ and /gallery/frame.html in the dev server. */
export function galleryHost(): Plugin {
  return {
    name: "cmux-dev-gallery",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use(async (request, response, next) => {
        const url = new URL(request.url ?? "/", "http://localhost");
        if (url.pathname === "/gallery") {
          response.statusCode = 302;
          response.setHeader("Location", `/gallery/${url.search}`);
          return response.end();
        }
        const page = /^\/gallery\/(index\.html|frame\.html)?$/.exec(url.pathname);
        if (!page) return next();
        const name = page[1] ?? "index.html";
        try {
          let html = fs.readFileSync(path.join(galleryDir, name), "utf8");
          // The page's relative script sources are relative to src/gallery, not /gallery/.
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
