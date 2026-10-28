// DESKTOP-FEEL (R139): the behavior half of the first layer of every first-party page (the CSS half
// is desktop.css, imported here so one import brings both). Importing the module installs it once.
// It handles no Cmd or Ctrl chord: the host owns those (Cmd-A selects only inside the focused field,
// Cmd-F is the page's find command, the native menu shows only Copy on a selection).
import "./desktop.css";
// LIQUID GLASS: the `.ui-glass` surface and its tokens; its lens (ui/glass/lens.ts) loads after.
import "../../ui/glass/glass.css";
// RUNNING-WAVE: the one shimmer across running indicators (ui/wave.ts).
import "../../ui/wave.css";
import { parseComputedColor } from "../../backdrop";
import { experimentArm } from "../../experiments/experiment";
import { installScrollers } from "../../scrollers";
import { chromiumGlassUnderlay } from "../../ui/glass/chromiumUnderlay.experiment";
import { installBackdropFallback } from "../../ui/glass/glassState";
import { installSpinnerClock } from "../../ui/spinnerClock";
import { installTooltips } from "../../ui/titleTooltips";
import { installWave } from "../../ui/wave";
import { installImeKeyLayer } from "./imeKeys";
import { installWebSwap } from "./webSwap";

/** The marker desktopLayer.test.ts and debug checks read: the layer ran in this document. */
export const DESKTOP_LAYER_ATTRIBUTE = "data-cmux-desktop";

/** On `<html>` while the page background (`--cmux-surface-background`, WebTheme.swift) is not
 * opaque: the page sits on the window tint over the material and art (pageBase.css lifts the
 * tertiary text tier there). */
export const SEE_THROUGH_ATTRIBUTE = "data-cmux-see-through";

/** On `<html>`: the arm of chromium-glass-underlay, how much theme surface a floating glass lays
 * under its tint in a see-through Chromium page (glass.css). With none yet, the default arm's. */
export const GLASS_UNDERLAY_ATTRIBUTE = "data-glass-underlay";

/** The host call a drawn title bar's double-click makes (the window's title bar action). */
export const TITLE_BAR_DOUBLE_CLICK = "cmux.app.window.title_bar_double_click";

type Caller = { call(op: string, params: unknown): Promise<unknown> };

let caller: Caller | null = null;

/** Gives the layer the page client, for the title bar double-click (pages without one skip it). */
export function setDesktopCaller(client: Caller | null): void {
  caller = client;
}

/** True when `target` is inside a region a page marked as its title bar (`data-titlebar`). */
export function isTitleBar(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false;
  const region = target.closest("[data-titlebar]");
  // Controls inside a title bar keep their own double-click.
  return region !== null && target.closest("button, input, textarea, select, a, [role='button']") === null;
}

export function installDesktopLayer(doc: Document = document): void {
  const root = doc.documentElement;
  if (root.hasAttribute(DESKTOP_LAYER_ATTRIBUTE)) return;
  root.setAttribute(DESKTOP_LAYER_ATTRIBUTE, "");
  // Spellcheck only where a page asks for it (prose inputs set spellcheck="true").
  root.spellcheck = false;
  // SCROLLBARS-THIN: library scrollers follow the host's data-scrollers (scrollers.ts).
  installScrollers(doc);
  // All first-party pages get the same native-feeling title tooltip. It replaces the browser's
  // delayed, clipping title bubble while preserving the title as the source of truth.
  installTooltips(doc);
  // SYNCED-SPINNERS: every `cmux-spin` spinner keeps the shared phase (ui/spinnerClock.ts).
  installSpinnerClock(doc);
  // RUNNING-WAVE: no wave runs while the page is hidden (ui/wave.ts).
  installWave(doc);
  // CHROMIUM OVER THE WINDOW GLASS: the glass underlay's strength (chromiumUnderlay.experiment.ts).
  root.setAttribute(GLASS_UNDERLAY_ATTRIBUTE, experimentArm(chromiumGlassUnderlay));
  const view = doc.defaultView;
  if (!view) return;
  // IME-KEYS: keys an input method is using never reach page handlers (imeKeys.ts).
  installImeKeyLayer(doc);
  // WEB-SWAP: the page answers whether a web update may reload it now (webSwap.ts).
  installWebSwap(doc);
  // HAIRLINE: rims and rings in whole device pixels at every scale and zoom (desktop.css).
  updateHairline(doc);
  // A page-zoom or uiScale change resizes the CSS viewport; it may not fire the resolution query.
  view.addEventListener("resize", () => updateHairline(doc));
  // SEE-THROUGH: follows the host's theme payload (window.cmuxTheme.apply fires `cmux-theme`).
  updateSeeThrough(doc);
  view.addEventListener("cmux-theme", () => updateSeeThrough(doc));
  // LIQUID GLASS: the wallpaper lens behind every `.ui-glass` (inert under plain glass, Reduce
  // Transparency, with no host still or with no glass on the page). The fallback keeps a still the
  // host sends before the lens chunk arrives; the WebGL engine stays out of each page's eager budget.
  installBackdropFallback(view);
  void import("../../ui/glass/lens").then(({ installGlassLens }) => installGlassLens(doc));
  // A drop never navigates the page: a page that takes drops handles them (and calls
  // preventDefault itself); everything else is refused here.
  view.addEventListener("dragover", (event) => {
    if (!event.defaultPrevented && event.dataTransfer) event.dataTransfer.dropEffect = "none";
    event.preventDefault();
  });
  view.addEventListener("drop", (event) => event.preventDefault());
  view.addEventListener("dblclick", (event) => {
    if (caller && isTitleBar(event.target)) void caller.call(TITLE_BAR_DOUBLE_CLICK, {}).catch(() => undefined);
  });
}

/** Per document: the ratio its hairline tokens were set for and the query watching for a change. */
const hairlineWatches = new WeakMap<Document, { ratio: number; query?: MediaQueryList; listener: () => void }>();

/** Sets `--cmux-hairline` (one device pixel) and `--cmux-hairline-ring` (the whole device pixels
 * nearest one CSS pixel) on the root from devicePixelRatio, and again whenever it changes: a display
 * move, the host's page zoom or uiScale. A rim thinner than a device pixel breaks at its rounded
 * corners in macOS WebKit (desktop.css). */
export function updateHairline(doc: Document = document): void {
  const view = doc.defaultView;
  if (!view) return;
  const ratio = view.devicePixelRatio > 0 ? view.devicePixelRatio : 1;
  const watch = hairlineWatches.get(doc);
  if (watch?.ratio === ratio) return;
  watch?.query?.removeEventListener("change", watch.listener);
  const root = doc.documentElement.style;
  root.setProperty("--cmux-hairline", `${1 / ratio}px`);
  root.setProperty("--cmux-hairline-ring", `${Math.max(1, Math.round(ratio)) / ratio}px`);
  const listener = () => updateHairline(doc);
  const query = typeof view.matchMedia === "function" ? view.matchMedia(`(resolution: ${ratio}dppx)`) : undefined;
  query?.addEventListener("change", listener);
  hairlineWatches.set(doc, { ratio, query, listener });
}

/** Sets or clears ``SEE_THROUGH_ATTRIBUTE`` from the resolved page background. Without a host theme
 * (the plain-browser dev loop) the page is on the browser's canvas, not art: the attribute stays off. */
export function updateSeeThrough(doc: Document = document): void {
  const root = doc.documentElement;
  const view = doc.defaultView;
  if (!view || view.getComputedStyle(root).getPropertyValue("--cmux-surface-background").trim() === "") {
    root.removeAttribute(SEE_THROUGH_ATTRIBUTE);
    return;
  }
  const probe = doc.createElement("span");
  probe.style.cssText =
    "position:absolute;width:0;height:0;visibility:hidden;pointer-events:none;background-color:var(--cmux-surface-background)";
  root.append(probe);
  const color = parseComputedColor(view.getComputedStyle(probe).backgroundColor);
  probe.remove();
  root.toggleAttribute(SEE_THROUGH_ATTRIBUTE, color !== null && color.a < 1);
}

if (typeof document !== "undefined") installDesktopLayer();
