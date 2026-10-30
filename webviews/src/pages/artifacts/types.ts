// The Artifacts page's ops (`cmux.artifacts.*`): the app relays each to one cmux-platform
// `/v1/artifacts` read with its own bearer (ArtifactsPageProvider.swift); the page never sees a token.

export const ArtifactsOps = {
  /** `{ref?, path?}` → `ArtifactsTree`: the immediate children of `path`. */
  tree: "cmux.artifacts.tree",
  /** `{path, ref?}` → `ArtifactFile`. */
  file: "cmux.artifacts.file",
  /** `{path?, ref?, limit?}` → `ArtifactHistory`, newest first. */
  history: "cmux.artifacts.history",
} as const;

export interface ArtifactTreeEntry {
  name: string;
  path: string;
  type: "blob" | "tree";
  size?: number;
}

export interface ArtifactsTree {
  ref: string;
  sha: string;
  entries: ArtifactTreeEntry[];
}

/** Who saved a commit: the agent session, machine and harness, when the saver said. */
export interface ArtifactTrailers {
  session?: string;
  machine?: string;
  harness?: string;
}

export interface ArtifactCommit {
  sha: string;
  parents: string[];
  message: string;
  authorName: string;
  /** Milliseconds since the epoch. */
  time: number;
  trailers: ArtifactTrailers;
  paths?: string[];
}

export interface ArtifactHistory {
  commits: ArtifactCommit[];
}

export interface ArtifactFile {
  path: string;
  size: number;
  contentType: string;
  /** The commit the read resolved to. */
  commit: string;
  /** Absent when `tooLarge`. Base64 when `encoding` says so (bytes that are not UTF-8). */
  content?: string;
  encoding?: "base64";
  tooLarge?: boolean;
}
