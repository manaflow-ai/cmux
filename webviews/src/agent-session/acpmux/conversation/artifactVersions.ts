// A document's versions (cx-ncc.64, Claude parity): a reply that rewrites a document the chat already
// has (same kind, same title) is its next version, and the side panel steps between them. Read with
// the transcript's own block parser (Markdown.tsx), so a version is a fence the chat drew with Open.
import { artifactKind, documentName, type Artifact } from "./artifactPreview";
import { parseMarkdown, type MdBlock } from "./markdownModel";
import { PrefixFlatCache } from "./prefixFlatMap";

export type ArtifactSourceRow = {
  id: string;
  version: number;
  kind: string;
  text?: string;
  at?: number;
  streaming?: boolean;
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
/// title, or that the replies do not hold, is its only version. `documents`: the replies' documents in
/// reading order (`finishedReplyDocuments`, `replyDocuments`).
export function artifactVersions(documents: readonly Artifact[], artifact: Artifact): Artifact[] {
  const name = documentName(artifact);
  if (!name) return [artifact];
  const versions: Artifact[] = [];
  const seen = new Set<string>();
  for (const document of documents) {
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

/// A reply the document scans read: a transcript row, kept by its object.
export type Reply = { readonly text?: string };
const NO_DOCUMENTS: readonly Artifact[] = [];

/// A reply's documents, parsed once per row: the panel and Session Info read them again on every
/// streamed delta. Kept by the row's object (the client keeps an unchanged row's object, direct.ts
/// `OrderedRows`), so a chat of any length parses only the rows an update changed, and a closed
/// chat's rows take their entries with them. A cache by reply text that emptied itself at 512
/// replies parsed every reply of a longer chat again on each update.
const parsed = new WeakMap<Reply, { readonly text: string; readonly documents: readonly Artifact[] }>();
export function replyDocuments(reply: Reply): readonly Artifact[] {
  const text = reply.text ?? "";
  const known = parsed.get(reply);
  if (known?.text === text) return known.documents;
  const found = text ? [...documents(parseMarkdown(text))] : NO_DOCUMENTS;
  parsed.set(reply, { text, documents: found });
  return found;
}

/// The documents of the finished replies among `rows`, in reading order. A pass reads again only
/// the rows after the kept prefix (prefixFlatMap.ts), so a streamed token reads its own row only.
const finishedDocuments = new PrefixFlatCache<ArtifactSourceRow, Artifact>(
  (row) => (row.kind === "assistant" && !row.streaming && row.text ? replyDocuments(row) : NO_DOCUMENTS),
  6,
);
export function finishedReplyDocuments(rows: readonly ArtifactSourceRow[]): readonly Artifact[] {
  return finishedDocuments.read(rows).items;
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
/// text once (Session Info's Outputs lists them).
export function chatDocuments(rows: readonly ArtifactSourceRow[]): Artifact[] {
  const seen = new Set<string>();
  const found: Artifact[] = [];
  for (const document of finishedReplyDocuments(rows)) {
    if (seen.has(document.code)) continue;
    seen.add(document.code);
    found.push(document);
  }
  return found;
}
