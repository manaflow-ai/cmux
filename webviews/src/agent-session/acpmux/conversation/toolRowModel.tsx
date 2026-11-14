import { type ReactNode } from "react";
import { Globe, Magnifier, OpenBook, Pencil, TerminalSquare, ToolGroup } from "./icons";

/// ACP tool kinds (`ToolKind`) to row glyphs.
export function toolIcon(kind?: string): ReactNode {
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
      return <Globe size={16} />;
    default:
      return <ToolGroup size={16} />;
  }
}
