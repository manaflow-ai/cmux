// Tool calls that hand the transcript HTML to show live: `cmux mcp`'s `render` and T3 Code's
// `html_render`, under whatever prefix the harness gives an MCP tool (`mcp__cmux__render`,
// `cmux.render`, `cmux/render`). An ended turn draws each as a render card (RenderCard.tsx).
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type RenderCall = {
  html: string;
  /// The card's heading, when the call names one.
  title?: string;
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
  return { html, title };
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
