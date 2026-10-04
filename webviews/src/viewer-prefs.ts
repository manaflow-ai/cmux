import { sanitizeCollapsedFiles } from "./collapsed-files";
import { callDiffComments, diffCommentsBridgeAvailable } from "./comments/bridge";
import { DIFF_PREFS_GET_OP, DIFF_PREFS_SET_OP, pageDiffPrefsClient } from "./diff/pageStore";
import type { DiffViewerOptions } from "./pierre-options";

/**
 * Globally persisted diff viewer display preferences: the split/unified layout
 * plus the options-menu toggles, and the files collapsed from their header
 * caret (`collapsedFiles`, see collapsed-files.ts). The collapse-all toggle
 * (`collapsed`) is intentionally session-local.
 *
 * Persistence goes through the native `cmuxDiffComments` bridge
 * (`viewerPrefs.get` / `viewerPrefs.set`) so preferences survive page reloads,
 * new diff panels, and app restarts (#5284). `localStorage` is kept as a
 * best-effort fallback for pages opened outside cmux, because generated viewer
 * origins do not reliably persist web storage.
 *
 * On the shared page host the prefs are `diff.*` settings: `cmux.diff.prefs.get` and
 * `cmux.diff.prefs.set {key, value}` (diff/pageStore.ts), and web storage is never touched (the
 * page host pool clears it). The host seeds first paint through `payload.viewerOptions`.
 */
export type ViewerPrefs = Partial<Omit<DiffViewerOptions, "collapsed">> & { collapsedFiles?: string[] };

const persistedOptionsKey = "cmux.diffViewer.options";
// Layout-only key from before options were persisted as one object.
const legacyLayoutKey = "cmux.diffViewer.layout";

export function sanitizeViewerPrefs(raw: unknown): ViewerPrefs {
  if (raw == null || typeof raw !== "object") {
    return {};
  }
  const source = raw as Record<string, unknown>;
  const prefs: ViewerPrefs = {};
  if (source.layout === "split" || source.layout === "unified") {
    prefs.layout = source.layout;
  }
  if (source.diffIndicators === "bars" || source.diffIndicators === "classic" || source.diffIndicators === "none") {
    prefs.diffIndicators = source.diffIndicators;
  }
  for (const key of ["wordWrap", "wordDiffs", "lineNumbers", "showBackgrounds", "expandUnchanged"] as const) {
    if (typeof source[key] === "boolean") {
      prefs[key] = source[key];
    }
  }
  const collapsedFiles = sanitizeCollapsedFiles(source.collapsedFiles);
  if (collapsedFiles != null) {
    prefs.collapsedFiles = collapsedFiles;
  }
  return prefs;
}

export async function loadViewerPrefs(): Promise<ViewerPrefs> {
  const page = pageDiffPrefsClient();
  if (page) {
    try {
      const value = await page.call<{ prefs?: unknown }>(DIFF_PREFS_GET_OP, {});
      return sanitizeViewerPrefs(value?.prefs);
    } catch {
      return {};
    }
  }
  if (diffCommentsBridgeAvailable()) {
    try {
      const value = await callDiffComments<{ preferences?: unknown }>("viewerPrefs.get", {});
      return sanitizeViewerPrefs(value?.preferences);
    } catch {
      // Fall through to local storage.
    }
  }
  return readLocalViewerPrefs();
}

export function saveViewerPrefs(prefs: ViewerPrefs): void {
  const sanitized = sanitizeViewerPrefs(prefs);
  const page = pageDiffPrefsClient();
  if (page) {
    for (const [key, value] of Object.entries(sanitized)) {
      page.call<unknown>(DIFF_PREFS_SET_OP, { key, value }).catch(() => {
        // Preferences are a convenience; a failed save must never surface.
      });
    }
    return;
  }
  if (diffCommentsBridgeAvailable()) {
    callDiffComments<unknown>("viewerPrefs.set", { preferences: sanitized }).catch(() => {
      // Preferences are a convenience; a failed save must never surface.
    });
  }
  writeLocalViewerPrefs(sanitized);
}

export function readLocalViewerPrefs(): ViewerPrefs {
  // The page host keeps prefs in settings (and seeds them in the payload), not web storage.
  if (pageDiffPrefsClient()) return {};
  try {
    const raw = window.localStorage.getItem(persistedOptionsKey);
    const prefs = raw == null ? {} : sanitizeViewerPrefs(JSON.parse(raw));
    if (prefs.layout == null) {
      const legacy = sanitizeViewerPrefs({ layout: window.localStorage.getItem(legacyLayoutKey) });
      if (legacy.layout != null) {
        prefs.layout = legacy.layout;
      }
    }
    return prefs;
  } catch {
    return {};
  }
}

function writeLocalViewerPrefs(prefs: ViewerPrefs): void {
  try {
    const existing = readLocalViewerPrefs();
    window.localStorage.setItem(persistedOptionsKey, JSON.stringify({ ...existing, ...prefs }));
  } catch {
    // Storage may be unavailable for some generated viewer origins.
  }
}
