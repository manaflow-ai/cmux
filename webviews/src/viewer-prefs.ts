import type { DiffViewerOptions } from "./pierre-options";

/**
 * Globally persisted diff viewer display preferences: the split/unified layout
 * plus the options-menu toggles. `collapsed` is intentionally session-local.
 *
 * Persistence goes through the native `cmuxDiffComments` bridge
 * (`viewerPrefs.get` / `viewerPrefs.set`) so preferences survive page reloads,
 * new diff panels, and app restarts (#5284). `localStorage` is kept as a
 * best-effort fallback for pages opened outside cmux — generated viewer
 * origins do not reliably persist web storage.
 */
export type ViewerPrefs = Partial<Omit<DiffViewerOptions, "collapsed">>;

const persistedOptionsKey = "cmux.diffViewer.options";

type PrefsMessageHandler = {
  postMessage(message: unknown): Promise<unknown>;
};

function prefsHandler(): PrefsMessageHandler | null {
  if (typeof window === "undefined") {
    return null;
  }
  const handler = (window as any).webkit?.messageHandlers?.cmuxDiffComments;
  return handler != null && typeof handler.postMessage === "function" ? handler : null;
}

export function sanitizeViewerPrefs(raw: unknown): ViewerPrefs {
  if (raw == null || typeof raw !== "object") {
    return {};
  }
  const source = raw as Record<string, unknown>;
  const prefs: ViewerPrefs = {};
  if (source.layout === "split" || source.layout === "unified") {
    prefs.layout = source.layout;
  }
  if (
    source.diffIndicators === "bars" ||
    source.diffIndicators === "classic" ||
    source.diffIndicators === "none"
  ) {
    prefs.diffIndicators = source.diffIndicators;
  }
  for (const key of [
    "wordWrap",
    "wordDiffs",
    "lineNumbers",
    "showBackgrounds",
    "expandUnchanged",
  ] as const) {
    if (typeof source[key] === "boolean") {
      prefs[key] = source[key];
    }
  }
  return prefs;
}

export async function loadViewerPrefs(): Promise<ViewerPrefs> {
  const handler = prefsHandler();
  if (handler != null) {
    try {
      const reply = (await handler.postMessage({ method: "viewerPrefs.get", params: {} })) as any;
      if (reply?.ok) {
        return sanitizeViewerPrefs(reply.value?.preferences);
      }
    } catch {
      // Fall through to local storage.
    }
  }
  return readLocalViewerPrefs();
}

export function saveViewerPrefs(prefs: ViewerPrefs): void {
  const sanitized = sanitizeViewerPrefs(prefs);
  const handler = prefsHandler();
  if (handler != null) {
    handler
      .postMessage({ method: "viewerPrefs.set", params: { preferences: sanitized } })
      .catch(() => {
        // Preferences are a convenience; a failed save must never surface.
      });
  }
  writeLocalViewerPrefs(sanitized);
}

function readLocalViewerPrefs(): ViewerPrefs {
  try {
    const raw = window.localStorage.getItem(persistedOptionsKey);
    return raw == null ? {} : sanitizeViewerPrefs(JSON.parse(raw));
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
