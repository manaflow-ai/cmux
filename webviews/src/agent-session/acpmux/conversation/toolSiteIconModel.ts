// The web page a fetch tool row read, for its site mark (ToolSiteIcon.tsx).
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const WEB_ADDRESS = /\bhttps?:\/\/[^\s"'<>`)\]]+/i;

/// The web page a fetch call read: its input's `url` (Claude Code's WebFetch `rawInput.url`), else
/// the first web address in its title ("Fetch https://…"). Undefined for any other call, and for a
/// fetch that has not completed: one waiting for the person's permission (`pending`), refused or
/// failed (`failed`), or running (`in_progress`, which a call with no status also reads as) shows
/// the globe, so a fetch the person never allowed sends nothing out.
export function fetchedUrl(tool: Pick<Tool, "kind" | "title" | "inputSummary" | "status">): string | undefined {
  if (tool.kind !== "fetch" || tool.status !== "completed") return undefined;
  const fromInput = /"url"\s*:\s*"(https?:\/\/[^"\s]+)"/i.exec(tool.inputSummary ?? "")?.[1];
  return fromInput ?? WEB_ADDRESS.exec(tool.title)?.[0];
}
