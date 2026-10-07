// A stage frame (frame.html): one variant of one entry, under the controls in its query. The shell
// shows these in iframes; the matrix runner screenshots them. Order matters: the clock, the
// language and the theme are in place before the page's own modules load, as the app has them
// before a page's first script runs.
import { installGalleryClock } from "../clock";
import { readEnv, widthPx } from "../env";
import type { GalleryEntry } from "../format";
import { errorText, readyEntries } from "../entryStore";
import { entryStore } from "../registry";
import { watchStageErrors } from "./liveErrors";
import { DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME, themeIsDark, type GhosttyTheme } from "../theme/ghostty";
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

// Every entry file loads on its own (entryStore.ts): a broken sibling file does not stop this stage.
const settled = await entryStore.settled();
const entryState = settled.find((state) => state.entry?.id === params.get("entry"));
// The live dev server: a save of this stage's entry file (or of any file, while it does not load)
// reloads this stage alone; compile errors in stage code show inside the stage (liveErrors.ts).
watchStageErrors(entryState?.path);
const entry: GalleryEntry =
  readyEntries(settled).find((candidate) => candidate.id === params.get("entry")) ??
  fail(
    [
      `No gallery entry ${JSON.stringify(params.get("entry"))}.`,
      ...settled
        .filter((state) => state.status === "error")
        .map((state) => `\n${state.path} does not load:\n${errorText(state.error)}`),
    ].join("\n"),
  );
const variantName = params.get("variant") ?? Object.keys(entry.variants)[0]!;
if (!entry.variants[variantName]) fail(`No variant ${JSON.stringify(variantName)} in ${entry.id}`);

// The app's language: WebKit reports the app's preferred localizations as navigator.languages.
for (const key of ["languages", "language"] as const)
  Object.defineProperty(Navigator.prototype, key, {
    configurable: true,
    get: () => (key === "languages" ? [env.locale] : env.locale),
  });

const theme = themeNamed(env.theme, DEFAULT_DARK_THEME);
const scheme = env.colorScheme === "auto" ? (themeIsDark(theme) ? "dark" : "light") : env.colorScheme;
// Pages that hold both sides (the diff and markdown appearance) get the theme on the side the
// window shows and the default on the other, as `theme = light:A,dark:B` would.
const pair =
  scheme === "dark"
    ? { dark: theme, light: themeNamed(DEFAULT_LIGHT_THEME, DEFAULT_LIGHT_THEME) }
    : { dark: themeNamed(DEFAULT_DARK_THEME, DEFAULT_DARK_THEME), light: theme };
const tokens = themeTokens(theme);

emulateMedia({
  "prefers-color-scheme": scheme,
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

// An experiment's arm (the compare view's cells, the matrix runner's experiment cases): the page
// reads it through experimentArm(), and the harness controls every Web Animation it starts.
const experiment =
  entry.experiment && params.get("exp") === entry.experiment.definition.id ? entry.experiment : undefined;
const arm =
  experiment && params.get("arm") && Object.hasOwn(experiment.definition.arms, params.get("arm")!)
    ? params.get("arm")!
    : experiment?.definition.defaultArm;
const experimentRunner = experiment ? await import("./experimentRunner") : undefined;
if (experiment && arm) {
  globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, [experiment.definition.id]: arm };
  root.dataset.galleryArm = arm;
  experimentRunner!.installAnimationControl();
}

const log: { method: string; params?: unknown }[] = [];
(window as unknown as { cmuxGalleryLog: typeof log }).cmuxGalleryLog = log;
const context: StageContext = {
  env,
  theme,
  pair,
  tokens,
  agentTheme: agentPaneTheme(tokens, env.reducedMotion),
  appearance: diffAppearance(pair, { family: env.fontFamily || undefined, size: env.fontSize || undefined }),
  log: (method, params) => log.push({ method, params }),
};

function markReady(): void {
  if (window.cmuxGalleryPlayReport) root.dataset.galleryPlay = window.cmuxGalleryPlayReport.status;
  root.dataset.galleryReady = "1";
  parent.postMessage({ type: "cmux-gallery-stage", status: "ready", width: widthPx(env.width, entry.widths) }, "*");
}

/** The variant's play steps (play.ts), then ready: the state the stage shows is the played one. */
async function playThenReady(): Promise<void> {
  const play = entry.variants[variantName]?.play;
  if (play) {
    const { runPlay } = await import("./playRunner");
    const report = await runPlay(play, { anchors: entry.anchors, checks: entry.checks });
    window.cmuxGalleryPlayReport = report;
    parent.postMessage({ type: "cmux-gallery-play", report }, "*");
  }
  if (experiment && experimentRunner && arm) await experimentRunner.prepareExperiment(experiment, params, arm);
  markReady();
  if (experiment && experimentRunner) experimentRunner.announceReady(experiment);
}

/** Ready once the page has painted and its DOM has been still for a moment (fonts loaded). */
function markReadyWhenStill(): void {
  let timer = 0;
  const started = performance.now();
  const done = () => {
    observer.disconnect();
    void playThenReady();
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
    case "apps-page":
      return (await import("./pages")).mountAppsPage(entry.variants[variantName]!, context);
    case "cloud-page":
      return (await import("./pages")).mountCloudPage(entry.variants[variantName]!, context);
    case "coderouter-page":
      return (await import("./pages")).mountCodeRouterPage(entry.variants[variantName]!, context);
    case "changelog-page":
      return (await import("./pages")).mountChangelogPage(entry.variants[variantName]!, context);
    case "icon-picker-page":
      return (await import("./pages")).mountIconPickerPage(entry.variants[variantName]!, context);
    case "editor-page":
      return (await import("./pages")).mountEditorPage(entry.variants[variantName]!, context);
    case "history-page":
      return (await import("./pages")).mountHistoryPage(entry.variants[variantName]!, context);
    case "keybindings-page":
      return (await import("./pages")).mountKeybindingsPage(entry.variants[variantName]!, context);
    case "settings-page":
      return (await import("./pages")).mountSettingsPage(entry.variants[variantName]!, context);
    case "passwords-page":
      return (await import("./pages")).mountPasswordsPage(entry.variants[variantName]!, context);

    case "component":
      return (await import("./component")).mountComponent(entry, entry.variants[variantName]!, context);
    case "native":
      // Drawn by the DEBUG native gallery (CmuxNextGallery); its snapshots join the matrix index.
      document.body.textContent = `${entry.id}#${variantName} is a native view: open it in the cmux-next DEBUG gallery.`;
      document.body.style.cssText = "font: 13px system-ui; color: var(--cmux-text-secondary); padding: 16px";
      return;
  }
}

// The stage is the surface alone, at the size its frame gives it (window mode sizes the frame to
// the pane the surface has in the app; nothing of the native window is drawn).
const start = mount().then(markReadyWhenStill);
start.catch((error: unknown) =>
  fail(
    `${entry.id}#${variantName} failed to mount:\n${error instanceof Error ? (error.stack ?? error.message) : String(error)}`,
  ),
);
