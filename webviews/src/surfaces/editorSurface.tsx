import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { resolveDiffViewerAppearance } from "../appearance";
// Side-effect import: installs `MonacoEnvironment` before any editor is created.
import type * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import "../editor/monacoEnvironment";
import { EditorApp } from "../editor/EditorApp";
import editorStyles from "../editor/editor.css?inline";
import { createEditorLabelResolver } from "../editor/editorLabels";
import { preloadGrammarForPath } from "../editor/monacoLanguages";
import { defineMonacoThemes } from "../editor/monacoTheme";
import { EditorSaveController, mapEditorSaveReply, type EditorSaveRequest } from "../editor/saveController";
import { createWebviewsRouter } from "../router";
import type { DiffViewerConfig } from "../types";
import { installWebviewStyles } from "./installWebviewStyles";

// Options the page must never accept from config, even though the CLI already
// curates `editor.*`: these control the document model, theme, layout strategy,
// or the editability invariant, and letting config override them would break
// the surface or its read-only guarantee. Defense-in-depth — the page can be
// served from hand-authored HTML, so we re-filter here too.
const FORBIDDEN_MONACO_OPTIONS = new Set([
  "model",
  "value",
  "language",
  "theme",
  "readOnly",
  "domReadOnly",
  "automaticLayout",
]);

/** Drop forbidden keys from a config-provided Monaco options object. */
function pickSafeMonacoOptions(
  raw: Record<string, unknown> | undefined,
): monaco.editor.IStandaloneEditorConstructionOptions {
  if (!raw || typeof raw !== "object") {
    return {};
  }
  const safe: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(raw)) {
    if (!FORBIDDEN_MONACO_OPTIONS.has(key)) {
      safe[key] = value;
    }
  }
  return safe as monaco.editor.IStandaloneEditorConstructionOptions;
}

function readConfig(): DiffViewerConfig {
  const element = document.getElementById("cmux-editor-config");
  if (!element?.textContent) {
    throw new Error("Missing cmux editor config");
  }
  try {
    return JSON.parse(element.textContent);
  } catch (error) {
    throw new Error(`Invalid cmux editor config JSON: ${String(error)}`);
  }
}

/**
 * Installs Monaco's stylesheet. The webviews build has no HTML entry, so Vite
 * does not inject `monaco-vendor.css` automatically. We fetch it and inject it
 * as an inline `<style>` rather than linking it: the editor surface is served
 * through the diff viewer custom scheme, whose page CSP allows `connect-src
 * 'self'` (the fetch) and `style-src 'unsafe-inline'` (the injected style) but
 * not an external `<link>` stylesheet or `font-src`. The codicon icon font is
 * therefore skipped for v1 (core editing/highlighting does not need it).
 */
async function injectMonacoStylesheet(): Promise<void> {
  if (document.querySelector("style[data-cmux-monaco-css]")) {
    return;
  }
  // Resolved at runtime (the asset exists next to the chunks when served), not
  // at build time, so tell Vite not to try to resolve it during the build.
  const href = new URL(/* @vite-ignore */ "../assets/monaco-vendor.css", import.meta.url).href;
  try {
    const response = await fetch(href);
    if (!response.ok) {
      return;
    }
    const css = await response.text();
    const style = document.createElement("style");
    style.dataset.cmuxMonacoCss = "true";
    style.textContent = css;
    document.head.append(style);
  } catch {
    // The editor still mounts without its stylesheet; leave it unstyled rather
    // than blocking the surface on a CSS fetch failure.
  }
}

type EditorSaveMessageHandler = {
  postMessage: (request: EditorSaveRequest | { probe: true }) => Promise<unknown>;
};

/**
 * Resolves the native save bridge. Present only when the app registered the
 * `cmuxEditorSave` script message handler for this page (writable `cmux edit`
 * surfaces); absent in plain browsers and for read-only files. The Swift side
 * re-validates the page's scheme token on every message, so the handler being
 * visible to page JS is not what authorizes the write.
 */
async function resolveSaveBridge(): Promise<
  ((request: EditorSaveRequest) => Promise<ReturnType<typeof mapEditorSaveReply>>) | null
> {
  const webkit = (
    window as unknown as {
      webkit?: { messageHandlers?: { cmuxEditorSave?: EditorSaveMessageHandler } };
    }
  ).webkit;
  const handler = webkit?.messageHandlers?.cmuxEditorSave;
  if (!handler || typeof handler.postMessage !== "function") {
    return null;
  }
  // Probe the write capability before unlocking the buffer: the handler is
  // installed on every browser webview, but authorization is the in-memory
  // token registration, which dies with the app instance. Without this check
  // a session-restored page would accept edits it can never save.
  try {
    const probeReply = (await handler.postMessage({ probe: true })) as { ok?: unknown } | null;
    if (probeReply?.ok !== true) {
      return null;
    }
  } catch {
    return null;
  }
  return async (request) => mapEditorSaveReply(await handler.postMessage(request));
}

/**
 * Loads the Monaco view state (scroll/cursor/selection/folding) persisted to
 * the native sidecar before the last webview unload. Authorized by the page's
 * scheme token, so it resolves for read-only files too. Returns null when there
 * is no saved state, the bridge is absent, or the round-trip fails.
 */
async function loadRestoredViewState(): Promise<monaco.editor.ICodeEditorViewState | null> {
  const handler = (
    window as unknown as {
      webkit?: { messageHandlers?: { cmuxEditorSave?: { postMessage: (m: unknown) => Promise<unknown> } } };
    }
  ).webkit?.messageHandlers?.cmuxEditorSave;
  if (!handler || typeof handler.postMessage !== "function") {
    return null;
  }
  try {
    const reply = (await handler.postMessage({ loadViewState: true })) as
      | { ok?: unknown; value?: { viewState?: unknown } }
      | null;
    if (reply?.ok !== true) {
      return null;
    }
    const viewState = reply.value?.viewState;
    return viewState ? (viewState as monaco.editor.ICodeEditorViewState) : null;
  } catch {
    return null;
  }
}

/**
 * Boots the Monaco editor surface: reads its injected config, registers
 * cmux-derived themes, then renders `EditorApp` through the shared router.
 * Loaded as its own lazy chunk so other surfaces never pay for Monaco.
 */
export async function mountEditorSurface(rootElement: HTMLElement): Promise<void> {
  const config = readConfig();
  installWebviewStyles("editor", editorStyles);
  await injectMonacoStylesheet();
  const appearance = resolveDiffViewerAppearance(config.payload?.appearance);
  const themes = defineMonacoThemes(appearance.themes.dark, appearance.themes.light);
  const prefersDark = window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? true;
  const themeName = prefersDark ? themes.dark : themes.light;
  const activeTheme = prefersDark ? appearance.themes.dark : appearance.themes.light;
  const filePath = typeof config.payload?.filePath === "string" ? config.payload.filePath : "untitled.txt";
  const content = typeof config.payload?.content === "string" ? config.payload.content : "";
  if (typeof config.payload?.title === "string" && config.payload.title.trim() !== "") {
    document.title = config.payload.title;
  }
  const labels = createEditorLabelResolver(config.payload?.labels);
  // Read-only unless the CLI explicitly marked the file writable AND the app
  // exposed the save bridge; either one missing means edits would be silently
  // discarded when the pane closes, so the buffer stays locked.
  const saveBridge = config.payload?.readOnly === false ? await resolveSaveBridge() : null;
  const readOnly = saveBridge === null;
  const saveController = readOnly
    ? null
    : new EditorSaveController({
        bridge: saveBridge,
        baselineSha256:
          typeof config.payload?.contentSha256 === "string" ? config.payload.contentSha256 : null,
      });
  // Load the file's Monarch grammar before mounting so the editor tokenizes
  // synchronously on first render (the WKWebView does not reliably repaint the
  // lazy async re-tokenization).
  await preloadGrammarForPath(filePath);
  // User Monaco options from `editor.*` in cmux.json (CLI-curated, re-filtered
  // here) are applied AFTER cmux's defaults so the user wins, but `readOnly` is
  // re-applied last so configuration can never make a read-only file editable.
  const userOptions = pickSafeMonacoOptions(config.payload?.editorOptions);
  // Restore scroll/cursor from before the last webview unload. Resolved before
  // mount so EditorApp can apply it before first paint.
  const restoredViewState = await loadRestoredViewState();
  const router = createWebviewsRouter(() => (
    <EditorApp
      filePath={filePath}
      content={content}
      themeName={themeName}
      options={{
        fontFamily: appearance.fontFamily,
        fontSize: appearance.fontSize,
        lineHeight: appearance.lineHeight,
        minimap: { enabled: true },
        scrollBeyondLastLine: false,
        ...userOptions,
        readOnly,
      }}
      labels={labels}
      saveController={saveController}
      chrome={{ background: activeTheme.background, foreground: activeTheme.foreground }}
      restoredViewState={restoredViewState}
    />
  ));
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
