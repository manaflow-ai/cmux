import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { resolveDiffViewerAppearance } from "../appearance";
// Side-effect import: installs `MonacoEnvironment` before any editor is created.
import "../editor/monacoEnvironment";
import { EditorApp } from "../editor/EditorApp";
import editorStyles from "../editor/editor.css?inline";
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
 * Links Monaco's emitted stylesheet. The webviews build has no HTML entry, so
 * Vite does not inject `monaco-vendor.css` automatically. The CSS sits next to
 * the chunks (`assets/monaco-vendor.css`), and its font is a relative
 * `url(./codicon.ttf)`, so resolving the link href from this chunk's own URL
 * works regardless of where the host page is served.
 */
function linkMonacoStylesheet(): void {
  // Resolved at runtime (the asset exists next to the chunks when served), not
  // at build time, so tell Vite not to try to resolve it during the build.
  const href = new URL(/* @vite-ignore */ "../assets/monaco-vendor.css", import.meta.url).href;
  if (document.querySelector(`link[data-cmux-monaco-css]`)) {
    return;
  }
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = href;
  link.dataset.cmuxMonacoCss = "true";
  document.head.append(link);
}

export function mountEditorSurface(rootElement: HTMLElement): void {
  const config = readConfig();
  installWebviewStyles("editor", editorStyles);
  linkMonacoStylesheet();
  const appearance = resolveDiffViewerAppearance(config.payload?.appearance);
  const themes = defineMonacoThemes(appearance.themes.dark, appearance.themes.light);
  const prefersDark = window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? true;
  const themeName = prefersDark ? themes.dark : themes.light;
  const filePath = typeof config.payload?.filePath === "string" ? config.payload.filePath : "untitled.txt";
  const content = typeof config.payload?.content === "string" ? config.payload.content : "";
  if (typeof config.payload?.title === "string" && config.payload.title.trim() !== "") {
    document.title = config.payload.title;
  }
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
