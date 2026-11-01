// A stage frame (frame.html): one variant of one entry, under the controls in its query. The shell
// shows these in iframes; the matrix runner screenshots them. Order matters: the clock, the
// language and the theme are in place before the page's own modules load, as the app has them
// before a page's first script runs.
import { installGalleryClock } from "../clock";
import { overPicture, readEnv, widthPx } from "../env";
import { readTunes } from "../../experiments/tunable";
import { readOptions } from "../options";
import type { GalleryEntry } from "../format";
import { errorText, readyEntries } from "../entryStore";
import { createFrameEntryStore } from "../registry";
import { watchStageErrors } from "./liveErrors";
import { DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME, themeIsDark, type GhosttyTheme } from "../theme/ghostty";
import { agentPaneTheme, diffAppearance, themeTokens, webThemePayload } from "../theme/web";
import { deriveAppTheme } from "../../theme/appTheme";
import themes from "virtual:cmux-gallery/themes";
import webThemeBootstrap from "virtual:cmux-gallery/web-theme";
import type { StageContext } from "./context";
import { emulateMedia } from "./media";
import { installUiFont } from "./uiFont";
import { setLastingGrace } from "../../ui/lasting";
import "./frame.css";
import revision from "virtual:cmux-gallery/revision";
import { isSubpixelLayoutShift, resolveTarget, type LoadReport, type Shift } from "../play";
import { startBoxTracker } from "../shift";

installGalleryClock();
// A fixture's lasting states (disconnected, offline) show at once, not after the pages' grace.
setLastingGrace(0);

const params = new URLSearchParams(location.search);
const env = readEnv(params);
const root = document.documentElement;
const stageRoot = document.getElementById("root");
const sourceHint = params.get("source") || undefined;

// A frame can be opened directly while the shell is still loading unrelated gallery modules.
// Keep that wait explicit so a slow sibling never looks like a broken white page.
const requestedId = params.get("entry");
const entryStore = createFrameEntryStore(sourceHint);
if (requestedId && stageRoot) {
  stageRoot.textContent = `Loading ${requestedId}…`;
  stageRoot.className = "gallery-frame-loading";
}

function fail(message: string): never {
  root.dataset.galleryReady = "error";
  document.body.textContent = message;
  document.body.className = "gallery-frame-error";
  parent.postMessage({ type: "cmux-gallery-stage", status: "error", message }, "*");
  throw new Error(message);
}

const byName = new Map(themes.map((theme) => [theme.name, theme]));
const themeNamed = (name: string, fallback: string): GhosttyTheme =>
  byName.get(name) ?? byName.get(fallback) ?? fail(`No Ghostty theme named ${JSON.stringify(name)}`);

if (sourceHint && entryStore.getSnapshot().length === 0)
  fail(`No gallery entry source ${JSON.stringify(sourceHint)}. The link is stale; reopen it from the shell.`);

// A frame renders one requested entry. Resolve it as soon as that entry loads; a broken or slow
// sibling must never leave a valid stage blank while the shell is still auditing the full registry.
// A missing entry still falls back to the full settled list so the error can name the bad sources.
const match = requestedId ? await entryStore.find(requestedId) : undefined;
const settled = match?.entry ? undefined : await entryStore.settled();
const entryState = match?.state ?? settled?.find((state) => state.entry?.id === requestedId);
// The live dev server: a save of this stage's entry file (or of any file, while it does not load)
// reloads this stage alone; compile errors in stage code show inside the stage (liveErrors.ts).
watchStageErrors(entryState?.path);
const entry: GalleryEntry =
  match?.entry ??
  (settled ? readyEntries(settled).find((candidate) => candidate.id === requestedId) : undefined) ??
  fail(
    [
      `No gallery entry ${JSON.stringify(requestedId)}.`,
      ...(settled ?? [])
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
const tokens = themeTokens(theme, env.accent);
// The background axis: over a picture the page is see-through, as over the user's in the app.
const seeThrough = overPicture(env);

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
installUiFont();
(window as unknown as { cmuxTheme: { apply(payload: unknown): void } }).cmuxTheme.apply(
  webThemePayload(tokens, deriveAppTheme(theme, env.accent), seeThrough),
);
if (seeThrough) {
  const [{ applyGalleryBackground }, { default: metrics }] = await Promise.all([
    import("./background"),
    import("virtual:cmux-gallery/metrics"),
  ]);
  // The same window-mode test as the shell's stage (Stage.tsx): page entries sit in a real pane.
  const windowed = env.frame === "window" && entry.host !== "native" && entry.host !== "component";
  applyGalleryBackground(env, tokens, { windowed, metrics });
}
// Document scale and the chrome scale are separate. The app sets pageZoom for the former and
// this token for the latter; gallery exposes both so each sheet is reproducible.
if (env.scale !== 1) root.style.zoom = String(env.scale);
root.style.setProperty("--cmux-ui-scale", String(env.scale));
root.style.setProperty("--cmux-interface-scale", String(env.interfaceScale));
// Entries were imported before the token was set: chat sizing (chatWidth.ts) reads it again.
window.dispatchEvent(new Event("cmux-ui-scale-change"));
root.dataset.galleryEntry = entry.id;
root.dataset.galleryVariant = variantName;
root.dataset.gallerySource = entryState?.path ?? "";
root.dataset.galleryEntryVersion = String(entryState?.version ?? "");
root.dataset.galleryRevision = revision.sha;

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

// Edited tunables (the stage's curve editors): the page reads them through tunableValue().
globalThis.cmuxTunables = { ...globalThis.cmuxTunables, ...readTunes(params.get("tune") ?? "") };
// The entry's changed options (options.ts): the component host applies them to the variant's props.
const optionValues = readOptions(params.get("opts") ?? "");

const log: { method: string; params?: unknown }[] = [];
(window as unknown as { cmuxGalleryLog: typeof log }).cmuxGalleryLog = log;
const context: StageContext = {
  env,
  theme,
  pair,
  tokens,
  agentTheme: agentPaneTheme(tokens, env.reducedMotion, seeThrough),
  appearance: diffAppearance(pair, { family: env.fontFamily || undefined, size: env.fontSize || undefined }),
  log: (method, params) => log.push({ method, params }),
  options: optionValues,
};

if (stageRoot) {
  stageRoot.textContent = "";
  stageRoot.className = "";
}

function markReady(): void {
  if (window.cmuxGalleryPlayReport) root.dataset.galleryPlay = window.cmuxGalleryPlayReport.status;
  root.dataset.galleryReady = "1";
  parent.postMessage(
    {
      type: "cmux-gallery-stage",
      status: "ready",
      width: widthPx(env.width, entry.widths),
      source: entryState?.path,
      version: entryState?.version,
      revision: revision.sha,
    },
    "*",
  );
}

declare global {
  interface Window {
    cmuxGalleryLoadReport?: LoadReport;
  }
}

/**
 * Opening the stage, measured like a play step: the browser's layout-shift entries since navigation
 * and the tracked rows' boxes frame by frame (shift.ts), from before the mount until the play starts.
 * A surface draws its final layout in its first frame (design/motion-and-polish.md: "No flicker, no
 * layout shift"); the composer gap that jumps after load or the rail that grows in steps scores here.
 */
const loadShifts: Shift[] = [];
type ShiftEntry = PerformanceEntry & {
  value: number;
  sources?: { node?: Node; previousRect?: DOMRectReadOnly; currentRect?: DOMRectReadOnly }[];
};
const noteLoadShifts = (entries: PerformanceEntryList) => {
  for (const shift of entries as ShiftEntry[]) {
    const sources = shift.sources ?? [];
    if (isSubpixelLayoutShift(sources)) continue;
    loadShifts.push({
      value: shift.value,
      sources: sources.map(({ node }) =>
        node instanceof Element
          ? `${node.tagName.toLowerCase()}${typeof node.className === "string" && node.className ? `.${node.className.split(" ")[0]}` : ""}`
          : "#text",
      ),
    });
  }
};
const loadObserver = PerformanceObserver.supportedEntryTypes?.includes("layout-shift")
  ? new PerformanceObserver((list) => noteLoadShifts(list.getEntries()))
  : undefined;
loadObserver?.observe({ type: "layout-shift", buffered: true });
const loadBoxes = startBoxTracker(document, {
  extra: () => (entry.anchors ?? []).flatMap((target) => resolveTarget(document, target) ?? []),
});

function finishLoad(): void {
  if (window.cmuxGalleryLoadReport) return;
  noteLoadShifts(loadObserver?.takeRecords() ?? []);
  loadObserver?.disconnect();
  const boxes = loadBoxes.stop();
  window.cmuxGalleryLoadReport = {
    layoutShift: Math.round(loadShifts.reduce((sum, shift) => sum + shift.value, 0) * 1e5) / 1e5,
    shifts: loadShifts.slice(0, 24),
    boxShift: boxes.score,
    boxMoves: boxes.moves,
  };
}

/** The variant's play steps (play.ts), then ready: the state the stage shows is the played one. */
async function playThenReady(): Promise<void> {
  finishLoad();
  const variant = entry.variants[variantName];
  const play = variant?.play;
  if (play) {
    const { runPlay } = await import("./playRunner");
    const report = await runPlay(play, {
      anchors: entry.anchors,
      checks: { ...entry.checks, ...variant.checks },
    });
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
    // A play or experiment that throws (a module that fails to load mid-run) is the stage's error,
    // not a stage that never reports ready.
    playThenReady().catch((error: unknown) =>
      fail(
        `${entry.id}#${variantName} failed to play:\n${error instanceof Error ? (error.stack ?? error.message) : String(error)}`,
      ),
    );
  };
  const arm = () => {
    clearTimeout(timer);
    timer = window.setTimeout(done, performance.now() - started > 4000 ? 0 : 250);
  };
  const waitForImages = async () => {
    const pending = [...document.images]
      .filter((image) => !image.complete || image.naturalWidth === 0)
      .map(
        (image) =>
          new Promise<void>((resolve) => {
            const finish = () => {
              image.removeEventListener("load", finish);
              image.removeEventListener("error", finish);
              resolve();
            };
            image.addEventListener("load", finish, { once: true });
            image.addEventListener("error", finish, { once: true });
            window.setTimeout(finish, 2000);
          }),
      );
    await Promise.all(pending);
    arm();
  };
  const observer = new MutationObserver(arm);
  observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
  void document.fonts.ready.then(waitForImages);
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
      document.body.className = "gallery-frame-native";
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
