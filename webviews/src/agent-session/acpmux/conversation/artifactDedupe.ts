import type { Artifact } from "./artifactPreview";

/// Keep one revision for each recorded document body, in the same oldest-first order as the chat.
export function uniqueArtifacts(artifacts: readonly Artifact[]): Artifact[] {
  const seen = new Set<string>();
  const unique: Artifact[] = [];
  for (const artifact of artifacts) {
    if (seen.has(artifact.code)) continue;
    seen.add(artifact.code);
    unique.push(artifact);
  }
  return unique;
}
