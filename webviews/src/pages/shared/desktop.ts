// DESKTOP-FEEL (R139): the behavior half of the first layer of every first-party page (the CSS half
// is desktop.css, imported here so one import brings both). Importing the module installs it once.
// It handles no Cmd or Ctrl chord: the host owns those (Cmd-A selects only inside the focused field,
// Cmd-F is the page's find command, the native menu shows only Copy on a selection).
import "./desktop.css";
import { installScrollers } from "../../scrollers";
import { installTooltips } from "../../ui/titleTooltips";

/** The marker desktopLayer.test.ts and debug checks read: the layer ran in this document. */
export const DESKTOP_LAYER_ATTRIBUTE = "data-cmux-desktop";

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
  // SCROLLBARS-FOLLOW-MACOS: library scrollers follow the host's data-scrollers (scrollers.ts).
  installScrollers(doc);
  // All first-party pages get the same native-feeling title tooltip. It replaces the browser's
  // delayed, clipping title bubble while preserving the title as the source of truth.
  installTooltips(doc);
  const view = doc.defaultView;
  if (!view) return;
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

if (typeof document !== "undefined") installDesktopLayer();
