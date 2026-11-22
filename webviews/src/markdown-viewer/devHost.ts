// Dev server only (/markdown, dev-server/plugins.ts): stands in for the Swift host of
// Resources/markdown-viewer/shell.html (MarkdownWebRenderer.swift on main) so the shell runs in a
// plain browser against a real markdown file. The server fills the shell's {{placeholders}} the way
// MarkdownViewerAssets.shellHTML does; this module then plays the host's two roles:
//   - render: fetch the file and call `window.__cmuxRenderMarkdown(md)`, again on every save;
//   - the `cmuxLib` message handler: `{lib}` loads mermaid / vega-lite and calls `__cmuxLibLoaded`,
//     `{action: "resolveMarkdownFile"}` answers `__cmuxMarkdownFileResolved`,
//     `{action: "openMarkdownFile"}` navigates to that file.
// Shell <style> edits arrive as `cmux-markdown:styles` and replace the style text in place.

type LibMessage = { lib: string };
type ActionMessage = { action: string; requestId?: string; path?: string };

type ShellWindow = Window & {
  __cmuxRenderMarkdown?: (markdown: string) => void;
  __cmuxLibLoaded?: (name: string) => void;
  __cmuxMarkdownFileResolved?: (result: { requestId: string; exists: boolean; path: string }) => void;
  __cmuxApplyTheme?: () => void;
};

const shell = window as ShellWindow;
const file = new URLSearchParams(location.search).get("file") ?? "";

async function render(): Promise<void> {
  const response = await fetch(`/__cmux-markdown/content?file=${encodeURIComponent(file)}`, { cache: "no-store" });
  const text = await response.text();
  if (!response.ok) throw new Error(`markdown dev host: ${text}`);
  shell.__cmuxRenderMarkdown?.(text);
}

function loadLib(name: string): void {
  const script = document.createElement("script");
  script.src = `/__cmux-markdown/lib/${encodeURIComponent(name)}.js`;
  script.onload = () => shell.__cmuxLibLoaded?.(name);
  document.head.append(script);
}

async function resolveMarkdownFile(requestId: string, rawPath: string): Promise<void> {
  const query = new URLSearchParams({ from: file, path: rawPath });
  const response = await fetch(`/__cmux-markdown/resolve?${query}`, { cache: "no-store" });
  const result = response.ok
    ? ((await response.json()) as { exists: boolean; path: string })
    : { exists: false, path: "" };
  shell.__cmuxMarkdownFileResolved?.({ requestId, ...result });
}

async function openMarkdownFile(rawPath: string): Promise<void> {
  const query = new URLSearchParams({ from: file, path: rawPath });
  const response = await fetch(`/__cmux-markdown/resolve?${query}`, { cache: "no-store" });
  const result = response.ok ? ((await response.json()) as { exists: boolean; path: string }) : undefined;
  if (result?.exists) location.search = `?file=${encodeURIComponent(result.path)}`;
}

const cmuxLib = {
  postMessage(message: LibMessage | ActionMessage): void {
    if ("lib" in message) return loadLib(message.lib);
    if (message.action === "resolveMarkdownFile" && message.requestId && message.path)
      void resolveMarkdownFile(message.requestId, message.path);
    else if (message.action === "openMarkdownFile" && message.path) void openMarkdownFile(message.path);
  },
};
// Never replace a real host.
const handlers = (window.webkit?.messageHandlers ?? {}) as Record<string, unknown>;
if (!handlers.cmuxLib) {
  window.webkit = { ...window.webkit, messageHandlers: { ...handlers, cmuxLib } } as Window["webkit"];
}

if (import.meta.hot) {
  import.meta.hot.on("cmux-markdown:styles", (styles: string[]) => {
    document.querySelectorAll<HTMLStyleElement>("style[data-cmux-shell-style]").forEach((element) => {
      const next = styles[Number(element.dataset.cmuxShellStyle)];
      if (typeof next === "string" && element.textContent !== next) element.textContent = next;
    });
    shell.__cmuxApplyTheme?.();
  });
  import.meta.hot.on("cmux-markdown:content", (changed: { file: string }) => {
    if (changed.file === file) void render();
  });
}

await render();
document.documentElement.dataset.cmuxMarkdownDevRendered = "true";
