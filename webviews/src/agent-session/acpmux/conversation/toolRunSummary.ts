// A run of tool calls between two pieces of text, summarized as Codex does once it settles:
// "Edited a file, read files, ran commands", opened to list the calls.
import type { AcpmuxActivity } from "../model";

/// What a call did, in the order Codex names them in a run's summary.
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

/// A run in an ended turn (inside an open "Worked for") folds under one summary line once it
/// holds two or more calls. A live turn lists every call, so its height and the user's place
/// don't change as each call starts and ends.
export function isFoldedRun(items: readonly AcpmuxActivity[]): boolean {
  return items.filter((item) => item.tool).length >= 2;
}

/// The categories a run's calls fall in, in summary order. Searches count as reads when the
/// run also reads files, as Codex's "Read files, ran commands" does.
export function toolRunCategories(items: readonly AcpmuxActivity[]): ToolRunCategory[] {
  const present = new Set(items.filter((item) => item.tool).map((item) => toolRunCategory(item.tool!.kind)));
  if (present.has("read")) present.delete("searched");
  return ORDER.filter((category) => present.has(category));
}

/// "Edited a file, read files, ran commands".
export function toolRunSummary(items: readonly AcpmuxActivity[]): string {
  const tools = items.filter((item) => item.tool);
  const count = (category: ToolRunCategory) =>
    tools.filter((item) => {
      const own = toolRunCategory(item.tool!.kind);
      return own === category || (category === "read" && own === "searched");
    }).length;
  const phrase = (category: ToolRunCategory) => {
    const one = count(category) === 1;
    switch (category) {
      case "used":
        return one ? "used a tool" : "used tools";
      case "edited":
        return one ? "edited a file" : "edited files";
      case "read":
        return one ? "read a file" : "read files";
      case "searched":
        return "searched the code";
      case "web":
        return "searched the web";
      case "ran":
        return one ? "ran a command" : "ran commands";
    }
  };
  const text = toolRunCategories(items).map(phrase).join(", ");
  return text.charAt(0).toUpperCase() + text.slice(1);
}
