// A document a reply carries in a fence (cx-ncc.63, Claude parity): HTML, SVG and Markdown open in the
// side panel beside the chat (ArtifactPanel.tsx), drawn as they render with their source a tab away.
import { createContext } from "react";

export type ArtifactKind = "html" | "svg" | "markdown";
export type Artifact = { kind: ArtifactKind; lang: string; code: string };

export function artifactKind(_lang: string | undefined, _code: string): ArtifactKind | undefined {
  return undefined;
}

/// Opens a fence in the side panel; unset where the page has none (a gallery, a test).
export const ArtifactContext = createContext<((artifact: Artifact) => void) | undefined>(undefined);
