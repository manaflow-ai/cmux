import { type ReactNode } from "react";
import { Globe, Magnifier, OpenBook, Pencil, TerminalSquare, ToolGroup } from "./icons";
import { ToolSiteIcon } from "./ToolSiteIcon";

/// ACP tool kinds (`ToolKind`) to row glyphs. A fetch of a web page (`url`) shows its site's mark.
export function toolIcon(kind?: string, url?: string): ReactNode {
  switch (kind) {
    case "read":
      return <OpenBook />;
    case "edit":
    case "delete":
    case "move":
    case "fileChange":
      return <Pencil size={16} />;
    case "search":
      return <Magnifier />;
    case "execute":
      return <TerminalSquare />;
    case "fetch":
      return url ? <ToolSiteIcon url={url} /> : <Globe size={16} />;
    default:
      return <ToolGroup size={16} />;
  }
}
