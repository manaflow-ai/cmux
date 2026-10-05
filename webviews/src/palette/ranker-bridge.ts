import { rankPaletteRequest, type PaletteRankRequest } from "./ranker"

/** JavaScriptCore entry point used by the thin native palette bridge. */
export function installPaletteRankerBridge(target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>): void {
  target.__cmuxPaletteRank = (requestJSON: string): string => JSON.stringify(rankPaletteRequest(JSON.parse(requestJSON) as PaletteRankRequest))
}

installPaletteRankerBridge()
