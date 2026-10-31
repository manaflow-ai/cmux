// The glyph of a tool row that read a web page (a `fetch` call with an address, as Claude Code's
// WebFetch): the page's site mark in the row's icon slot (chips/SiteIcon.tsx), as T3 Code shows a
// website tool's favicon; a search, or a call with no address, keeps the globe (ToolRow.tsx toolIcon).
import type { AcpmuxActivity } from "../model";
import { SiteIcon } from "../chips/SiteIcon";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const WEB_ADDRESS = /\bhttps?:\/\/[^\s"'<>`)\]]+/i;

/// The web page a fetch call read: its input's `url` (Claude Code's WebFetch `rawInput.url`), else
/// the first web address in its title ("Fetch https://…"). Undefined for any other call.
export function fetchedUrl(tool: Pick<Tool, "kind" | "title" | "inputSummary">): string | undefined {
  if (tool.kind !== "fetch") return undefined;
  const fromInput = /"url"\s*:\s*"(https?:\/\/[^"\s]+)"/i.exec(tool.inputSummary ?? "")?.[1];
  return fromInput ?? WEB_ADDRESS.exec(tool.title)?.[0];
}

/// The row glyph for a fetch of `url`: its site's favicon, else the globe.
export function ToolSiteIcon({ url }: { url: string }) {
  return <SiteIcon href={url} size="row" />;
}
