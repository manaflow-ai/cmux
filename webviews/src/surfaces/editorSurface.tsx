import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { resolveDiffViewerAppearance } from "../appearance";
// Side-effect import: installs `MonacoEnvironment` before any editor is created.
import "../editor/monacoEnvironment";
import { EditorApp } from "../editor/EditorApp";
import editorStyles from "../editor/editor.css?inline";
import { preloadGrammarForPath } from "../editor/monacoLanguages";
import { defineMonacoThemes } from "../editor/monacoTheme";
import { createWebviewsRouter } from "../router";
import type { DiffViewerConfig } from "../types";
import { installWebviewStyles } from "./installWebviewStyles";

function readConfig(): DiffViewerConfig {
  const element = document.getElementById("cmux-editor-config");
  if (!element?.textContent) {
    throw new Error("Missing cmux editor config");
  }
  return JSON.parse(element.textContent);
}

/**
 * Boots the Monaco editor surface: reads its injected config, registers
 * cmux-derived themes, then renders `EditorApp` through the shared router.
 * Loaded as its own lazy chunk so other surfaces never pay for Monaco.
 */
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

export async function mountEditorSurface(rootElement: HTMLElement): Promise<void> {
  const config = readConfig();
  installWebviewStyles("editor", editorStyles);
  await injectMonacoStylesheet();
  const appearance = resolveDiffViewerAppearance(config.payload?.appearance);
  const themes = defineMonacoThemes(appearance.themes.dark, appearance.themes.light);
  const prefersDark = window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? true;
  const themeName = prefersDark ? themes.dark : themes.light;
  const filePath = typeof config.payload?.filePath === "string" ? config.payload.filePath : "untitled.txt";
  const content = typeof config.payload?.content === "string" ? config.payload.content : "";
  if (typeof config.payload?.title === "string" && config.payload.title.trim() !== "") {
    document.title = config.payload.title;
  }
  // Load the file's Monarch grammar before mounting so the editor tokenizes
  // synchronously on first render (the WKWebView does not reliably repaint the
  // lazy async re-tokenization).
  await preloadGrammarForPath(filePath);
  const router = createWebviewsRouter(() => (
    <EditorApp
      filePath={filePath}
      content={content}
      themeName={themeName}
      options={{
        fontFamily: appearance.fontFamily,
        fontSize: appearance.fontSize,
        lineHeight: appearance.lineHeight,
        readOnly: Boolean(config.payload?.readOnly),
        minimap: { enabled: true },
        scrollBeyondLastLine: false,
      }}
    />
  ));
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
