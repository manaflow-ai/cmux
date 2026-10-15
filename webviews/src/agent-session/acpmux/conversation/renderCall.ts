// Tool calls that hand the transcript HTML to show live: `cmux mcp`'s `render` and T3 Code's
// `html_render`, under whatever prefix the harness gives an MCP tool (`mcp__cmux__render`,
// `cmux.render`, `cmux/render`). An ended turn draws each as a render card (RenderCard.tsx).
// A harness with no render tool writes the page in a ```cmux-render fence instead (renderFence).
// A render that names an earlier render's id updates that card in place (cx-ncc.94, `renderPages`).
import { createContext } from "react";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { documentName, type Artifact } from "./artifactPreview";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type RenderCall = {
  html: string;
  /// The card's heading, when the call names one.
  title?: string;
  /// The page's render id (`renderId`): the id an update named, else the page's own. A fence has none.
  id?: string;
  /// The call named an earlier render's id: it updates that card.
  update?: boolean;
};

/// A render card's frame height before the page reports one (RenderCard.tsx).
export const RENDER_FRAME_MIN_HEIGHT = 120;

/// The tool's own name at the end of its title; a trailing "(server)" note is allowed.
const NAME = /(?:^|[_./:\s])(?:html_)?render(?:\s*\([^)]*\))?$/i;

/// Statuses of a call that did not render: it failed, or its turn was cancelled before it ran.
const NOT_RENDERED = new Set(["failed", "pending", "in_progress"]);

/// The HTML a tool call renders, or nil for every other call and one that did not run.
export function renderCall(tool: Tool): RenderCall | undefined {
  if (NOT_RENDERED.has(tool.status ?? "") || !NAME.test(tool.title.trim())) return undefined;
  const input = parseInput(tool.inputSummary);
  const html = input?.html;
  if (typeof html !== "string" || !html.trim()) return undefined;
  const title = typeof input?.title === "string" && input.title.trim() ? input.title.trim() : undefined;
  const update = typeof input?.id === "string" && input.id ? input.id : undefined;
  return update ? { html, title, id: update, update: true } : { html, title, id: renderId(html) };
}

/// The id `cmux mcp`'s render returns for a page (cmux-tui render_tool.rs `render_id`): `r`, FNV-1a 32
/// of its UTF-8 bytes in 8 hex digits, then its byte length in hex.
export function renderId(html: string): string {
  let id = ids.get(html);
  if (id) return id;
  const bytes = new TextEncoder().encode(html);
  let hash = 0x811c9dc5;
  for (const byte of bytes) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  id = `r${hash.toString(16).padStart(8, "0")}${bytes.length.toString(16)}`;
  // A page's id is read on every snapshot: a bounded cache, not a growing one.
  if (ids.size >= 256) ids.clear();
  ids.set(html, id);
  return id;
}
const ids = new Map<string, string>();

/// A render card: the call that drew it (its key, a tool-call id), the render id it answers to (its
/// first page's), and every page it showed, oldest first.
export type RenderPage = { first: string; id: string; calls: RenderCall[] };

/// Each render call's card, by the call's tool-call id. A render without an id is always a card of
/// its own, even for a page the chat showed before. A render with an id (an update, cx-ncc.94) joins
/// the most recent card that answers to that id, which shows its last page; one that finds none is
/// its own card.
export function renderPages(rows: readonly AcpmuxRow[]): Map<string, RenderPage> {
  const pages = new Map<string, RenderPage>();
  const latest = new Map<string, RenderPage>();
  for (const row of rows) {
    if (row.kind !== "activity") continue;
    for (const item of row.items ?? []) {
      const call = item.tool && renderCall(item.tool);
      if (!call?.id) continue;
      const card = call.update ? latest.get(call.id) : undefined;
      if (card) {
        if (card.calls.at(-1)!.html !== call.html) card.calls.push(call);
        pages.set(item.tool!.id, card);
        continue;
      }
      const page = { first: item.tool!.id, id: call.id, calls: [call] };
      pages.set(page.first, page);
      latest.set(page.id, page);
    }
  }
  return pages;
}

/// The open chat's render pages (`renderPages`); unset where there is no transcript (a gallery).
export const RenderPages = createContext<Map<string, RenderPage> | undefined>(undefined);

/// The pages a render card's Open lists as its versions, oldest first (`render` is the card's key);
/// nil for a document that is not a render card's (the fence versions apply, artifactVersions.ts).
export function renderVersions(pages: Map<string, RenderPage>, artifact: Artifact): Artifact[] | undefined {
  const page = artifact.render ? pages.get(artifact.render) : undefined;
  if (!page) return undefined;
  return page.calls.map((call) => ({ kind: "html", lang: "html", code: call.html, render: artifact.render }));
}

function parseInput(summary: string | undefined): Record<string, unknown> | undefined {
  if (!summary) return undefined;
  try {
    const value: unknown = JSON.parse(summary);
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

/// The fence language whose closed block draws as a render card in the reply (Markdown.tsx).
export const RENDER_FENCE = "cmux-render";

/// The page a reply's fence renders, or nil for every other fence. Its heading is the page's <title>.
export function renderFence(lang: string, code: string): RenderCall | undefined {
  if (lang.toLowerCase() !== RENDER_FENCE || !code.trim()) return undefined;
  const title = documentName({ kind: "html", lang: "html", code });
  return title ? { html: code, title } : { html: code };
}
