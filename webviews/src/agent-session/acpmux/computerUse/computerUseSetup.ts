// A Computer Use call macOS refused for a missing permission (`permission_missing`, cmux-computer-use
// engine.rs `ToolOutput::desktop`): the result names the app's setup (`setup_action`), and the chat shows
// Set Up Computer Use under the call, as Codex opens its Computer Use window when a call lacks a grant.
import type { AcpmuxActivity } from "../model";

/** The one app action the card runs (AgentPaneModel.computerUseSetupActions allows it, on a click). */
export const COMPUTER_USE_SETUP_ACTION = "palette.computerUse.setup";

/** The first JSON object in a tool's output (the result may carry a prose prefix). */
function payload(text: string | undefined): Record<string, unknown> | undefined {
  if (!text) return undefined;
  for (let start = text.indexOf("{"); start >= 0; start = text.indexOf("{", start + 1)) {
    const end = text.lastIndexOf("}");
    if (end <= start) return undefined;
    try {
      const parsed: unknown = JSON.parse(text.slice(start, end + 1));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed as Record<string, unknown>;
    } catch {
      // Not this brace; try the next one.
    }
  }
  return undefined;
}

/** The missing permission when `tool` is a Computer Use call refused for one, else undefined. */
export function computerUseSetupFor(tool: NonNullable<AcpmuxActivity["tool"]> | undefined): string | undefined {
  if (!tool?.output || !tool.output.includes("permission_missing")) return undefined;
  const data = payload(tool.output);
  if (data?.code !== "permission_missing" || data.setup_action !== COMPUTER_USE_SETUP_ACTION) return undefined;
  return typeof data.permission === "string" ? data.permission : "";
}
