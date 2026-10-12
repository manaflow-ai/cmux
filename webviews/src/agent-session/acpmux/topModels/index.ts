// The models each harness's picker lists first (Leo 2026-10-11): a short curated list per harness,
// one data file each (`<catalog harness id>.json`, `top` in order), so a release updates one file.
// Every other model folds under "More models"; search and Starred still reach all of them. A
// harness without a file lists its catalog's newest family instead (modelSections.ts).
import claude from "./claude.json";
import codex from "./codex.json";

const LISTS: Record<string, { top: string[] }> = { claude, codex };

/** The curated top model ids for catalog harness `id`, or undefined when it has no list. */
export function topModelsFor(id: string): readonly string[] | undefined {
  const list = LISTS[id]?.top;
  return list && list.length > 0 ? list : undefined;
}
