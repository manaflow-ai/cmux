// A run of tool calls between two pieces of text, summarized once it settles:
// "Edited a file, read 6 files, ran 4 commands", opened to list the calls.
import type { Translate } from "../i18n";
import { pathKey, toolCanonical, type AcpmuxActivity } from "../model";
import { editedPaths } from "../toolPaths";
import { mcpCall } from "./mcpCalls";

/// What a call did.
export type ToolRunCategory = "used" | "edited" | "read" | "searched" | "web" | "ran";

/// ACP tool kinds (`ToolKind`) to the summary's categories.
export function toolRunCategory(kind?: string): ToolRunCategory {
  switch (kind) {
    case "edit":
    case "delete":
    case "move":
    case "fileChange":
      return "edited";
    case "read":
      return "read";
    case "search":
      return "searched";
    case "fetch":
      return "web";
    case "execute":
      return "ran";
    default:
      return "used";
  }
}

/// What one call did. An MCP call used a tool whatever kind its harness gives it (Codex says
/// "execute" for every one).
function callCategory(tool: NonNullable<AcpmuxActivity["tool"]>): ToolRunCategory {
  return mcpCall(tool) ? "used" : toolRunCategory(tool.kind);
}

/// A run the Codex-style runs (Debug toggle) settle folds under one summary line once it holds two
/// or more calls. Otherwise every run lists its calls (TurnRows.tsx `shouldFoldToolRun`).
export function isFoldedRun(items: readonly AcpmuxActivity[]): boolean {
  return items.filter((item) => item.tool).length >= 2;
}

/// The categories a run's calls fall in, in the order the run first did each, as the Codex app
/// names a collapsed run ("Edited files, read files, ran commands"; Leo 2026-10-22: "this is
/// pretty good ui: … the collapsing i mean").
export function toolRunCategories(items: readonly AcpmuxActivity[]): ToolRunCategory[] {
  return [...new Set(items.filter((item) => item.tool).map((item) => callCategory(item.tool!)))];
}

/// The run's main kind of work, for its glyph: edits when it made any (what the run changed), else
/// the category with the most calls, the earlier one on a tie.
export function mainToolRunCategory(items: readonly AcpmuxActivity[]): ToolRunCategory | undefined {
  const counts = new Map<ToolRunCategory, number>();
  for (const item of items)
    if (item.tool) counts.set(callCategory(item.tool), (counts.get(callCategory(item.tool)) ?? 0) + 1);
  if (counts.has("edited")) return "edited";
  let main: ToolRunCategory | undefined;
  for (const [category, n] of counts) if (main === undefined || n > counts.get(main)!) main = category;
  return main;
}

/// "Read 6 files, ran 4 commands", in the language `t` speaks, counted as Claude desktop counts a
/// run (Leo 2026-10-21: "it can consolidate a ton of these tool calls"). Reads count the distinct
/// files they opened, edits the files they changed, every other category its calls.
export function toolRunSummary(t: Translate, items: readonly AcpmuxActivity[]): string {
  const tools = items.filter((item) => item.tool);
  const count = (category: ToolRunCategory) =>
    category === "edited"
      ? editedFiles(tools)
      : category === "read"
        ? readFiles(tools)
        : tools.filter((item) => callCategory(item.tool!) === category).length;
  const phrase = (category: ToolRunCategory) => {
    const n = count(category);
    const one = n === 1;
    switch (category) {
      case "used":
        return one ? t("toolRun.used.one") : t("toolRun.used.other", { n });
      case "edited":
        return one ? t("toolRun.edited.one") : t("toolRun.edited.other", { n });
      case "read":
        return one ? t("toolRun.read.one") : t("toolRun.read.other", { n });
      case "searched":
        return one ? t("toolRun.searched.one") : t("toolRun.searched.other", { n });
      case "web":
        return t("toolRun.web");
      case "ran":
        return one ? t("toolRun.ran.one") : t("toolRun.ran.other", { n });
    }
  };
  // A catalog separator, not Intl.ListFormat: its unit lists join zh-Hans with nothing and add
  // conjunctions in some languages, while the run reads as a plain comma list.
  const text = toolRunCategories(items).map(phrase).join(t("toolRun.separator"));
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/// The distinct files a run's reads opened, by their locations, or one per read without any.
function readFiles(tools: readonly AcpmuxActivity[]): number {
  const paths = new Set<string>();
  let unnamed = 0;
  for (const { tool } of tools) {
    if (callCategory(tool!) !== "read") continue;
    const locations = tool!.locations ?? [];
    if (!locations.length) unnamed += 1;
    for (const location of locations) paths.add(pathKey(location));
  }
  return paths.size + unnamed;
}

/// The files a run's edits changed: one Codex change can edit several, so a call counts each
/// file its diffs and locations name; one with no diff, each file its input names (a
/// multi-file patch, toolPaths.ts); or one when it names none. One file is one `pathKey`.
function editedFiles(tools: readonly AcpmuxActivity[]): number {
  const paths = new Set<string>();
  let unnamed = 0;
  for (const { tool } of tools) {
    if (toolRunCategory(tool!.kind) !== "edited") continue;
    const named = tool!.diffs?.length
      ? [...tool!.diffs, ...(tool!.locations ?? [])].map(pathKey)
      : editedPaths(tool!).map((path) => toolCanonical(tool!, path) ?? path);
    if (named.length === 0) unnamed += 1;
    for (const path of named) paths.add(path);
  }
  return paths.size + unnamed;
}
