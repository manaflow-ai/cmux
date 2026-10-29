// The render frame's stylesheet (RenderCard.tsx hands it over; AgentPaneRenderFrame.swift puts it
// first in the page's head). It gives the page the pane's theme as `--cmux-*` variables and a base
// stylesheet, so a page with no CSS of its own already reads as part of the chat: the pane's font,
// type scale, links, headings, tables, buttons, inputs and code, in the pane's light or dark, on a
// transparent background so the card's surface shows. Every base rule sits in `:where()` (no
// specificity), the variables included, and comes before the page's own styles, so any rule the
// page writes wins.
// The `render` tool's description (cmux-tui/.../mcp/render_tool.rs) lists the same variables.

/// The variables a page can use, each read from the pane's theme (or the pane's fixed scale) with
/// a fallback for a pane that has not themed yet.
export const RENDER_TOKENS: ReadonlyArray<readonly [name: string, source: string | null, fallback: string]> = [
  ["--cmux-text", "--agent-text", "CanvasText"],
  ["--cmux-muted", "--agent-muted", "GrayText"],
  ["--cmux-bg", "--agent-page-bg", "transparent"],
  ["--cmux-card", "--agent-surface", "color-mix(in srgb, CanvasText 5%, transparent)"],
  ["--cmux-border", "--agent-border", "color-mix(in srgb, CanvasText 12%, transparent)"],
  ["--cmux-accent", "--agent-accent", "LinkText"],
  ["--cmux-control", "--agent-control", "color-mix(in srgb, CanvasText 7%, transparent)"],
  ["--cmux-control-hover", "--agent-control-hover", "color-mix(in srgb, CanvasText 11%, transparent)"],
  ["--cmux-font", "--cv-font", '"Inter", system-ui, sans-serif'],
  ["--cmux-mono", "--font-mono", "ui-monospace, monospace"],
  ["--cmux-size-caption", "--text-caption", "11px"],
  ["--cmux-size-detail", "--text-detail", "12px"],
  ["--cmux-size-body", "--text-body", "13px"],
  ["--cmux-size-title", "--text-title", "15px"],
  ["--cmux-size-heading", "--text-heading", "17px"],
  ["--cmux-radius", null, "6px"],
  ["--cmux-space-1", null, "4px"],
  ["--cmux-space-2", null, "8px"],
  ["--cmux-space-3", null, "12px"],
  ["--cmux-space-4", null, "16px"],
];

/// The pane's theme as variables, then the base stylesheet.
export function renderFrameCSS(): string {
  const style = getComputedStyle(document.body);
  const read = (name: string | null, fallback: string) => (name && style.getPropertyValue(name).trim()) || fallback;
  const scheme = style.colorScheme.includes("dark") ? "dark" : "light";
  const tokens = RENDER_TOKENS.map(([name, source, fallback]) => `${name}:${read(source, fallback)}`);
  return `:where(:root){color-scheme:${scheme};${tokens.join(";")}}${BASE}`;
}

// The base sets colors, fonts and sizes only where the page leaves them to the browser, and
// never layout: no box-sizing, width, height or display, and no color on inline text a page
// colors through its parent. Controls get a minimum height, so a padded button keeps its own.
const BASE = [
  ":where(html){background:transparent;-webkit-text-size-adjust:100%}",
  // An inset by margin: a full-bleed page's `body{margin:0}` wins and fills the frame.
  ":where(body){margin:12px 14px;color:var(--cmux-text);",
  "font:var(--cmux-size-body)/1.5 var(--cmux-font);-webkit-font-smoothing:antialiased;overflow-wrap:break-word}",
  ":where(h1,h2,h3,h4,h5,h6){margin:0 0 6px;font-weight:600;line-height:1.3}",
  ":where(h1){font-size:var(--cmux-size-heading)}:where(h2){font-size:var(--cmux-size-title)}",
  ":where(h3,h4,h5,h6){font-size:var(--cmux-size-body)}",
  ":where(h1,h2,h3,h4):where(:not(:first-child)){margin-top:14px}",
  ":where(p,ul,ol,dl,table,pre,blockquote,figure){margin:0 0 10px}",
  ":where(ul,ol){padding-left:20px}:where(li + li){margin-top:2px}",
  ":where(small){font-size:var(--cmux-size-detail)}",
  ":where(figcaption,caption){color:var(--cmux-muted);font-size:var(--cmux-size-detail)}",
  ":where(a){color:var(--cmux-accent);text-decoration:underline;text-underline-offset:2px;",
  "text-decoration-color:color-mix(in srgb,currentColor 35%,transparent)}",
  ":where(a:hover){text-decoration-color:currentColor}",
  ":where(hr){margin:12px 0;border:0;border-top:1px solid var(--cmux-border)}",
  ":where(blockquote){padding-left:10px;color:var(--cmux-muted);box-shadow:inset 2px 0 var(--cmux-border)}",
  // Without a doctype (quirks mode) a table resets to the browser's 16px; it reads at the body's size.
  ":where(table){border-collapse:collapse;font-size:inherit;line-height:inherit;font-variant-numeric:tabular-nums}",
  ":where(th,td){padding:5px 14px 5px 0;text-align:left;vertical-align:top;border-bottom:1px solid var(--cmux-border)}",
  ":where(th){color:var(--cmux-muted);font-size:var(--cmux-size-detail);font-weight:500}",
  ":where(tr:last-child > td){border-bottom:0}",
  ":where(code,kbd,samp,pre){font-family:var(--cmux-mono);font-size:0.92em}",
  ":where(pre){padding:8px 10px;border-radius:var(--cmux-radius);background:var(--cmux-control);overflow:auto;line-height:1.45}",
  ":where(button,input,select,textarea){font:inherit;color:inherit}",
  ":where(button,input[type=button],input[type=submit],input[type=reset]){min-height:26px;padding:0 10px;",
  "border:0;border-radius:var(--cmux-radius);background:var(--cmux-control);",
  "box-shadow:inset 0 0 0 0.5px var(--cmux-border);cursor:default;transition:background-color 120ms ease-out}",
  ":where(button:hover,input[type=button]:hover,input[type=submit]:hover){background:var(--cmux-control-hover)}",
  ":where(button:disabled){opacity:0.5}",
  ":where(input:not([type=checkbox],[type=radio],[type=range],[type=color],[type=button],[type=submit],[type=reset]),",
  "select){min-height:26px;padding:0 8px;border:0;border-radius:var(--cmux-radius);background:transparent;",
  "box-shadow:inset 0 0 0 1px var(--cmux-border)}",
  ":where(textarea){padding:6px 8px;border:0;border-radius:var(--cmux-radius);background:transparent;",
  "box-shadow:inset 0 0 0 1px var(--cmux-border)}",
  ":where(input:focus-visible,select:focus-visible,textarea:focus-visible,button:focus-visible){outline:1.5px solid var(--cmux-accent);outline-offset:1px}",
  ":where(input[type=checkbox],input[type=radio],input[type=range],progress){accent-color:var(--cmux-text)}",
].join("");
