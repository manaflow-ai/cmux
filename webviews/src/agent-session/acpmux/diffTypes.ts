// The shapes of a turn's file diffs (diff.ts builds them). A leaf: a module that needs only the shapes
// (changes/model.ts) imports them here, so its import graph does not reach diff.ts and the pane model.
export type DiffLine = { type: "context" | "add" | "del"; text: string; oldLine?: number; newLine?: number };
export type DiffHunk = {
  lines: DiffLine[];
  /// Checkpoint hunks can point back to the tool hunks that produced them. The tool view leaves
  /// this unset and uses its own hunkKey as the review identity.
  reviewKeys?: string[];
};
/// One tool call's change to a file. Line numbers are known for a new file, a file the agent
/// sent whole, or an edit whose tool call located its first line; a bare fragment has none.
export type DiffEdit = { toolId: string; hunks: DiffHunk[]; numbered: boolean };
export type TurnFile = {
  path: string;
  /// The file's canonical path (model.ts `pathKey`): what acpmux recorded for a tool call's file,
  /// or a turn checkpoint's `${root}/${path}`. Absent for a path recorded without one.
  canonical?: string;
  displayPath: string;
  edits: DiffEdit[];
  additions: number;
  deletions: number;
  created: boolean;
  /// A git scope's file that the change removed, or whose contents are not text.
  deleted?: boolean;
  binary?: boolean;
  /// A turn checkpoint's file that none of the turn's tool calls changed: read-only.
  outside?: boolean;
  /// The host returned only part of this file's patch, so hunk review is unsafe.
  patchTruncated?: boolean;
  /// The raw git patch when a scope supplied one, used to share blob identity with the full viewer.
  patch?: string;
  /// Git's content identity, supplied for hunk-only and binary native responses.
  blobFingerprint?: string;
};
