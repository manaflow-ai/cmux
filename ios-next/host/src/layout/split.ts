// Turns a cmux-next split tree into normalized pane rects.
//
// Tree nodes (list-workspaces, Screen.layout):
//   {type:"leaf", pane:Id}
//   {type:"split", dir:"right"|"down", ratio:number, a:Node, b:Node}
// `ratio` is the share of `a` (left for "right", top for "down").

import type { Rect } from "../protocol.ts";

export function paneRects(node: unknown, rect: Rect = { x: 0, y: 0, w: 1, h: 1 }, out = new Map<number, Rect>()): Map<number, Rect> {
  if (!node || typeof node !== "object") return out;
  const n = node as { type?: string; pane?: number; dir?: string; ratio?: number; a?: unknown; b?: unknown };
  if (n.type === "leaf" && typeof n.pane === "number") {
    out.set(n.pane, round(rect));
    return out;
  }
  if (n.type === "split") {
    const r = Math.min(1, Math.max(0, typeof n.ratio === "number" ? n.ratio : 0.5));
    if (n.dir === "down") {
      paneRects(n.a, { x: rect.x, y: rect.y, w: rect.w, h: rect.h * r }, out);
      paneRects(n.b, { x: rect.x, y: rect.y + rect.h * r, w: rect.w, h: rect.h * (1 - r) }, out);
    } else {
      paneRects(n.a, { x: rect.x, y: rect.y, w: rect.w * r, h: rect.h }, out);
      paneRects(n.b, { x: rect.x + rect.w * r, y: rect.y, w: rect.w * (1 - r), h: rect.h }, out);
    }
  }
  return out;
}

function round(r: Rect): Rect {
  const f = (v: number) => Math.round(v * 10_000) / 10_000;
  return { x: f(r.x), y: f(r.y), w: f(r.w), h: f(r.h) };
}
