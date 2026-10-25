// Document history for both transcript fences and completed writes. Fences join by kind/title;
// written documents join by recorded file identity, so a renamed title keeps its history.
import { artifactKind, artifactPath, documentName, type Artifact } from "./artifactPreview";
import { parseMarkdown, type MdBlock } from "./Markdown";
import { type AcpmuxRow } from "../model";
import { writtenArtifacts } from "./artifactWrites";

type ArtifactInput = string | AcpmuxRow;

/// The chat's documents of `artifact`'s kind and title, oldest first, each text once. One with no
/// title/path, or that the chat does not hold, is its only version.
export function artifactVersions(replies: readonly ArtifactInput[], artifact: Artifact): Artifact[] {
  const name = documentName(artifact);
  if (!name && !artifact.path) return [artifact];
  const versions: Artifact[] = [];
  const seen = new Set<string>();
  for (const reply of replies)
    for (const document of replyDocuments(reply)) {
      const same = artifact.path
        ? artifactPath(document) === artifactPath(artifact)
        : !document.path && documentName(document) === name;
      if (document.kind !== artifact.kind || seen.has(document.code) || !same) continue;
      seen.add(document.code);
      versions.push(document);
    }
  return seen.has(artifact.code) ? versions : [artifact];
}

/// A finished reply's documents, parsed once: the panel reads them again on every streamed delta.
const parsed = new Map<string, Artifact[]>();
const rowDocuments = new WeakMap<AcpmuxRow, Artifact[]>();
function replyDocuments(input: ArtifactInput): Artifact[] {
  if (typeof input !== "string") {
    let found = rowDocuments.get(input);
    if (!found) {
      found =
        input.kind === "assistant" && !input.streaming && input.text
          ? replyDocuments(input.text)
          : input.kind === "activity"
            ? writtenArtifacts(input)
            : [];
      rowDocuments.set(input, found);
    }
    return found;
  }
  const reply = input;
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
      if (kind && !block.open) yield { kind, lang: block.lang, code: block.code };
    } else if (block.type === "blockquote") yield* documents(block.children);
    else if (block.type === "list") for (const item of block.items) yield* documents(item.children);
}

/// Finished fences and whole HTML writes, oldest first, each identity/text once. Accepting plain
/// reply strings preserves callers that only have assistant text.
export function chatDocuments(replies: readonly ArtifactInput[]): Artifact[] {
  const seen = new Set<string>();
  const found: Artifact[] = [];
  for (const reply of replies)
    for (const document of replyDocuments(reply)) {
      const key = JSON.stringify([document.kind, artifactPath(document) ?? null, document.code]);
      if (seen.has(key)) continue;
      seen.add(key);
      found.push(document);
    }
  return found;
}
