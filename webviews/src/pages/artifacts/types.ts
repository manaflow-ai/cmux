export type ArtifactKind = "html" | "markdown" | "json" | "image" | "other";
export type ArtifactTreeEntry = { name: string; path: string; type: "blob" | "tree"; size?: number };
export type ArtifactCommit = { sha: string; parents: string[]; message: string; authorName: string; time: string; trailers: { session?: string; machine?: string; harness?: string }; paths?: string[] };
export type ArtifactHistory = { commits: ArtifactCommit[] };
export type ArtifactFile = { path: string; content: string; contentType?: string; commit?: string };
export type ArtifactsTree = { ref: string; sha: string | null; entries: ArtifactTreeEntry[] };
export const ArtifactsOps = { tree: "cmux.artifacts.tree", file: "cmux.artifacts.file", history: "cmux.artifacts.history" } as const;
