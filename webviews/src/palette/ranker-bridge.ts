import { rankPaletteRequest, type PaletteRankEntry, type PaletteRankRequest } from "./ranker";

/** JavaScriptCore entry points used by the thin native palette bridge. The native side installs an
 * index's entries once per version (`__cmuxPaletteInstall`); a rank request for that version then
 * carries no entries, so a keystroke encodes and parses only the query. */
export function installPaletteRankerBridge(
  target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>,
): void {
  let installed: { version: number; entries: PaletteRankEntry[] } | undefined;
  target.__cmuxPaletteInstall = (version: number, entriesJSON: string): void => {
    installed = { version, entries: JSON.parse(entriesJSON) as PaletteRankEntry[] };
  };
  target.__cmuxPaletteRank = (requestJSON: string): string => {
    const request = JSON.parse(requestJSON) as PaletteRankRequest & { entries?: PaletteRankEntry[] | null };
    if (request.entries == null) {
      if (!installed || installed.version !== request.version) {
        throw new Error(`palette ranker: no entries installed for version ${String(request.version)}`);
      }
      request.entries = installed.entries;
    }
    return JSON.stringify(rankPaletteRequest(request));
  };
}

installPaletteRankerBridge();
