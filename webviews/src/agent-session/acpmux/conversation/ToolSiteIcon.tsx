// The glyph of a tool row that read a web page (a `fetch` call with an address, as Claude Code's
// WebFetch): the page's site mark in the row's icon slot (chips/SiteIcon.tsx), as T3 Code shows a
// website tool's favicon; a search, or a call with no address, keeps the globe (toolRowModel.tsx toolIcon).
import { SiteIcon } from "../chips/SiteIcon";

/// The row glyph for a fetch of `url`: its site's favicon, else the globe.
export function ToolSiteIcon({ url }: { url: string }) {
  return <SiteIcon href={url} size="row" />;
}
