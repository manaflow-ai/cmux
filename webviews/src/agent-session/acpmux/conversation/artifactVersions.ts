// A document's versions (cx-ncc.64, Claude parity): a reply that rewrites a document the chat already
// has (same kind, same title) is its next version, and the side panel steps between them. Read with
// the transcript's own block parser (Markdown.tsx), so a version is a fence the chat drew with Open.
import { artifactKind, documentName, type Artifact } from "./artifactPreview";
import { parseMarkdown, type MdBlock } from "./Markdown";

export type ArtifactSourceRow = {
  id: string;
  version: number;
  kind: string;
  text?: string;
  at?: number;
};

/// The row and parser block key identify one fence across streamed snapshots.
export function artifactIdentity(rowId: string, blockKey: string): string {
  return `${rowId}\u0000${blockKey}`;
}

/// Finds a newer source for one opened fence. A snapshot at or before `afterRevision` is stale,
/// so the panel keeps its last accepted source while an out-of-order harness update catches up.
export function artifactForIdentity(
  rows: readonly ArtifactSourceRow[],
  identity: string,
  afterRevision = -Infinity,
): Artifact | undefined {
  const separator = identity.lastIndexOf("\u0000");
  if (separator < 1) return undefined;
  const rowId = identity.slice(0, separator);
  const blockKey = identity.slice(separator + 1);
  const path = blockKey.split(".");
  const index = Number(path[0]);
  if (!/^\d+$/.test(path[0]!) || !Number.isSafeInteger(index)) return undefined;
  const row = rows.find((candidate) => candidate.id === rowId && candidate.kind === "assistant");
  if (!row || row.version <= afterRevision || !row.text) return undefined;
  let block = parseMarkdown(row.text)[index];
  for (let at = 1; block && at < path.length; at += 2) {
    const branch = path[at]!;
    const child = path[at + 1];
    if (child === undefined || !/^\d+$/.test(child)) return undefined;
    if (branch === "q" && block.type === "blockquote") block = block.children[Number(child)];
    else if (/^i\d+$/.test(branch) && block.type === "list")
      block = block.items[Number(branch.slice(1))]?.children[Number(child)];
    else return undefined;
  }
  if (!block || block.type !== "code") return undefined;
  const kind = artifactKind(block.lang, block.code);
  if (!kind) return undefined;
  return {
    kind,
    lang: block.lang ?? kind,
    code: block.code,
    identity,
    revision: row.version,
  };
}

/// The chat's documents of `artifact`'s kind and title, oldest first, each text once. One with no
/// title, or that the replies do not hold, is its only version.
export function artifactVersions(replies: readonly string[], artifact: Artifact): Artifact[] {
  const name = documentName(artifact);
  if (!name) return [artifact];
  const versions: Artifact[] = [];
  const seen = new Set<string>();
  for (const reply of replies)
    for (const document of replyDocuments(reply)) {
      if (document.kind !== artifact.kind || seen.has(document.code) || documentName(document) !== name) continue;
      seen.add(document.code);
      versions.push(document);
    }
  if (!seen.has(artifact.code)) {
    // A live rewrite is not finished yet, but it is still the newest version of this document.
    if (!artifact.identity || versions.length === 0) return [artifact];
    versions.push(artifact);
  }
  return versions;
}

/// A finished reply's documents, parsed once: the panel reads them again on every streamed delta.
const parsed = new Map<string, Artifact[]>();
function replyDocuments(reply: string): Artifact[] {
  let found = parsed.get(reply);
  if (!found) {
    found = [...documents(parseMarkdown(reply))];
    // Another chat's replies replace these, a bounded cache, not a growing one.
    if (parsed.size >= 512) parsed.clear();
    parsed.set(reply, found);
  }
  return found;
}

/// The fences in `blocks` the panel can draw, in reading order (quotes and list items hold fences too).
function* documents(blocks: readonly MdBlock[]): Generator<Artifact> {
  for (const block of blocks)
    if (block.type === "code") {
      const kind = artifactKind(block.lang, block.code);
      if (kind) yield { kind, lang: block.lang, code: block.code };
    } else if (block.type === "blockquote") yield* documents(block.children);
    else if (block.type === "list") for (const item of block.items) yield* documents(item.children);
}

/// The documents the chat's finished replies drew as fences the panel can open, oldest first, each
/// text once (the Inspector's Outputs lists them).
export function chatDocuments(replies: readonly string[]): Artifact[] {
  const seen = new Set<string>();
  const found: Artifact[] = [];
  for (const reply of replies)
    for (const document of replyDocuments(reply)) {
      if (seen.has(document.code)) continue;
      seen.add(document.code);
      found.push(document);
    }
  return found;
}
