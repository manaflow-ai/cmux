// A document's versions (cx-ncc.64, Claude parity): a reply that rewrites a document the chat already
// has (same kind, same title) is its next version, and the side panel steps between them. Read with
// the transcript's own block parser (Markdown.tsx), so a version is a fence the chat drew with Open.
import { artifactKind, documentName, type Artifact } from "./artifactPreview";
import { parseMarkdown, type MdBlock } from "./Markdown";

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
  return seen.has(artifact.code) ? versions : [artifact];
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
/// text once (Session Info's Outputs lists them).
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
