// The agent UI surfaces a tool row's calls carry (`tool.uiSurface`, direct.ts `mergeToolItem`),
// each a card under the row. Only with Labs `labs.agentUiSurfaces` on (agentUiSurfaces.ts); off,
// the row draws as before and nothing here mounts.
import { useAgentUiSurfaces } from "../agentUiSurfaces";
import type { AcpmuxRow } from "../model";
import { UiSurfaceCard } from "./UiSurfaceCard";

/// Whether any call in `row` carries a surface (cheap: the row's own items).
export const rowHasUiSurface = (row: AcpmuxRow) => !!row.items?.some((item) => item.tool?.uiSurface);

export function ToolUiSurfaces({ row }: { row: AcpmuxRow }) {
  const on = useAgentUiSurfaces();
  if (!on) return null;
  return (
    <>
      {row.items?.map((item) => {
        const surface = item.tool?.uiSurface;
        return surface ? <UiSurfaceCard key={surface.surfaceId} surface={surface} /> : null;
      })}
    </>
  );
}
