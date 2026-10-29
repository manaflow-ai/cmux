// The `render` row: an ended turn's render call.
import { memo } from "react";
import { RenderToolCard, canRender } from "../conversation/RenderCard";
import type { RowProps } from "./rowProps";

/// An ended turn's render call, live (conversation/RenderCard.tsx).
export const RenderRow = memo(
  function RenderRow({ row }: RowProps) {
    const tool = row.items?.[0]?.tool;
    return tool && canRender() ? <RenderToolCard tool={tool} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
