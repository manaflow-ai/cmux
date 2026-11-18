// Which look a node draws with, from its own data only (the model carries no styling):
//   approval  compact   one row, like a permission ask: no facts, no detail, not high risk
//             full      title, detail, a facts table, the answers at its foot
//             danger    high risk: the full card with a warning mark, a High risk tag and a red Approve
//   review    chips     short labels with no details: a wrap of chips
//             list      a radio (or checkbox) list, each option's detail under its label
//             ranked    a list of options in an order that means something (more than 4 with details)
//   choice    chips     up to 6 options; else a menu
import { chartSpec } from "../conversation/chartSpec";
import type { UiApprovalNode, UiChartNode, UiFieldNode, UiReviewNode } from "./model";

export type ApprovalLook = "compact" | "full" | "danger";
export type ReviewLook = "chips" | "list" | "ranked";

export function approvalLook(node: UiApprovalNode): ApprovalLook {
  if (node.risk === "high") return "danger";
  return node.facts.length === 0 && !node.detail ? "compact" : "full";
}

const CHIP_LABEL_MAX = 24;

export function reviewLook(node: UiReviewNode): ReviewLook {
  const details = node.options.some((option) => option.detail);
  if (!details && node.options.every((option) => option.label.length <= CHIP_LABEL_MAX)) return "chips";
  return details && node.options.length > 4 ? "ranked" : "list";
}

export function choiceLook(node: UiFieldNode): "chips" | "menu" {
  return (node.options?.length ?? 0) <= 6 ? "chips" : "menu";
}

/// A chart node as a Vega-Lite spec built by the chat's ```chart fence compiler
/// (conversation/chartSpec.ts), so it draws with the same Vega path and palette as a chart in a
/// reply. The x field has no name of its own in the model, so its axis carries no title.
export function chartSource(node: UiChartNode): string | undefined {
  const series = node.kind === "pie" ? node.series.slice(0, 1) : node.series;
  const rows = new Map<string | number, Record<string, string | number>>();
  for (const entry of series)
    for (const point of entry.points) {
      const row = rows.get(point.x) ?? { x: point.x };
      row[entry.name] = point.y;
      rows.set(point.x, row);
    }
  const compiled = chartSpec(
    JSON.stringify({
      type: node.kind,
      data: [...rows.values()],
      x: "x",
      y: series.map((entry) => entry.name),
      ...(node.yLabel ? { yTitle: node.yLabel } : {}),
    }),
  );
  if (!compiled) return undefined;
  const spec = JSON.parse(compiled) as { encoding?: { x?: Record<string, unknown> } };
  if (spec.encoding?.x) spec.encoding.x.title = null;
  return JSON.stringify(spec);
}
