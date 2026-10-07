// A stage frame (frame.html): one variant of one entry, under the controls in its query. The shell
// shows these in iframes; the matrix runner screenshots them. Order matters: the clock, the
// language and the theme are in place before the page's own modules load, as the app has them
// before a page's first script runs.
import { installGalleryClock } from "../clock";
import { readEnv, widthPx } from "../env";
import type { GalleryEntry } from "../format";
import { entries } from "../registry";
import { DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME, type GhosttyTheme } from "../theme/ghostty";
import { agentPaneTheme, diffAppearance, themeTokens, webThemePayload } from "../theme/web";
import themes from "virtual:cmux-gallery/themes";
import webThemeBootstrap from "virtual:cmux-gallery/web-theme";
import type { StageContext } from "./context";
import { emulateMedia } from "./media";

installGalleryClock();

const params = new URLSearchParams(location.search);
const env = readEnv(params);
const root = document.documentElement;

function fail(message: string): never {
  root.dataset.galleryReady = "error";
  document.body.textContent = message;
  document.body.style.cssText = "font: 13px ui-monospace, monospace; color: #c33; padding: 16px; white-space: pre-wrap";
  parent.postMessage({ type: "cmux-gallery-stage", status: "error", message }, "*");
  throw new Error(message);
}

const byName = new Map(themes.map((theme) => [theme.name, theme]));
const themeNamed = (name: string, fallback: string): GhosttyTheme =>
  byName.get(name) ?? byName.get(fallback) ?? fail(`No Ghostty theme named ${JSON.stringify(name)}`);

const entry: GalleryEntry =
  entries.find((candidate) => candidate.id === params.get("entry")) ??
  fail(`No gallery entry ${JSON.stringify(params.get("entry"))}`);
const variantName = params.get("variant") ?? Object.keys(entry.variants)[0]!;
if (!entry.variants[variantName]) fail(`No variant ${JSON.stringify(variantName)} in ${entry.id}`);

// The app's language: WebKit reports the app's preferred localizations as navigator.languages.
for (const key of ["languages", "language"] as const)
  Object.defineProperty(Navigator.prototype, key, {
    configurable: true,
    get: () => (key === "languages" ? [env.locale] : env.locale),
  });

const pair = { dark: themeNamed(env.dark, DEFAULT_DARK_THEME), light: themeNamed(env.light, DEFAULT_LIGHT_THEME) };
const theme = env.scheme === "dark" ? pair.dark : pair.light;
const tokens = themeTokens(theme);

emulateMedia({
  "prefers-color-scheme": env.scheme,
  "prefers-reduced-motion": env.reducedMotion ? "reduce" : "no-preference",
  "prefers-contrast": env.highContrast ? "more" : "no-preference",
});
// WebTheme: the app's document-start script, then its payload, as every cmux web view gets them.
// A classic script, as WKUserScript injects it.
const bootstrap = document.createElement("script");
bootstrap.textContent = webThemeBootstrap;
document.head.append(bootstrap);
bootstrap.remove();
(window as unknown as { cmuxTheme: { apply(payload: unknown): void } }).cmuxTheme.apply(webThemePayload(tokens));
// Interface scale: the app sets WKWebView.pageZoom (DesignSettings.uiScale).
if (env.scale !== 1) root.style.zoom = String(env.scale);
root.dataset.galleryEntry = entry.id;
root.dataset.galleryVariant = variantName;

const log: { method: string; params?: unknown }[] = [];
(window as unknown as { cmuxGalleryLog: typeof log }).cmuxGalleryLog = log;
const context: StageContext = {
  env,
  theme,
  pair,
  tokens,
  agentTheme: agentPaneTheme(tokens, env.reducedMotion),
  appearance: diffAppearance(pair, { family: env.font || undefined, size: env.size || undefined }),
  log: (method, params) => log.push({ method, params }),
};

/** Ready once the page has painted and its DOM has been still for a moment (fonts loaded). */
function markReadyWhenStill(): void {
  let timer = 0;
  const started = performance.now();
  const done = () => {
    observer.disconnect();
    root.dataset.galleryReady = "1";
    parent.postMessage({ type: "cmux-gallery-stage", status: "ready", width: widthPx(env.width, entry.widths) }, "*");
  };
  const arm = () => {
    clearTimeout(timer);
    timer = window.setTimeout(done, performance.now() - started > 4000 ? 0 : 250);
  };
  const observer = new MutationObserver(arm);
  observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
  void document.fonts.ready.then(arm);
}

async function mount(): Promise<void> {
  switch (entry.host) {
    case "agent-pane":
      return (await import("./agentPane")).mountAgentPane(entry.variants[variantName]!, context);
    case "markdown-page":
      return (await import("./pages")).mountMarkdownPage(entry.variants[variantName]!, context);
    case "diff-page":
      return (await import("./pages")).mountDiffPage(entry.variants[variantName]!, context);
    case "component":
      return (await import("./component")).mountComponent(entry, entry.variants[variantName]!, context);
    case "native":
      // Drawn by the DEBUG native gallery (CmuxNextGallery); its snapshots join the matrix index.
      document.body.textContent = `${entry.id}#${variantName} is a native view: open it in the cmux-next DEBUG gallery.`;
      document.body.style.cssText = "font: 13px system-ui; color: var(--cmux-text-secondary); padding: 16px";
      return;
  }
}

mount().then(markReadyWhenStill, (error: unknown) =>
  fail(`${entry.id}#${variantName} failed to mount:\n${error instanceof Error ? (error.stack ?? error.message) : String(error)}`),
);
