// A run of tool calls between two pieces of text, summarized once it settles:
// "Edited a file, read files, ran commands", opened to list the calls.
import type { Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";

/// What a call did, in the order a run's summary names them.
export type ToolRunCategory = "used" | "edited" | "read" | "searched" | "web" | "ran";

const ORDER: ToolRunCategory[] = ["used", "edited", "read", "searched", "web", "ran"];

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

/// A run in an ended turn (inside an open "Worked for") folds under one summary line once it
/// holds two or more calls. A live turn lists every call, so its height and the user's place
/// don't change as each call starts and ends.
export function isFoldedRun(items: readonly AcpmuxActivity[]): boolean {
  return items.filter((item) => item.tool).length >= 2;
}

/// The categories a run's calls fall in, in summary order. Searches count as reads when the
/// run also reads files, as in "Read files, ran commands".
export function toolRunCategories(items: readonly AcpmuxActivity[]): ToolRunCategory[] {
  const present = new Set(items.filter((item) => item.tool).map((item) => callCategory(item.tool!)));
  if (present.has("read")) present.delete("searched");
  return ORDER.filter((category) => present.has(category));
}

/// "Edited a file, read files, ran commands", in the language `t` speaks.
export function toolRunSummary(t: Translate, items: readonly AcpmuxActivity[]): string {
  const tools = items.filter((item) => item.tool);
  const count = (category: ToolRunCategory) =>
    tools.filter((item) => {
      const own = callCategory(item.tool!);
      return own === category || (category === "read" && own === "searched");
    }).length;
  const phrase = (category: ToolRunCategory) => {
    const one = count(category) === 1;
    switch (category) {
      case "used":
        return one ? t("toolRun.used.one") : t("toolRun.used.other");
      case "edited":
        return one ? t("toolRun.edited.one") : t("toolRun.edited.other");
      case "read":
        return one ? t("toolRun.read.one") : t("toolRun.read.other");
      case "searched":
        return t("toolRun.searched");
      case "web":
        return t("toolRun.web");
      case "ran":
        return one ? t("toolRun.ran.one") : t("toolRun.ran.other");
    }
  };
  // A catalog separator, not Intl.ListFormat: its unit lists join zh-Hans with nothing and add
  // conjunctions in some languages, while the run reads as a plain comma list.
  const text = toolRunCategories(items).map(phrase).join(t("toolRun.separator"));
  return text.charAt(0).toUpperCase() + text.slice(1);
}
