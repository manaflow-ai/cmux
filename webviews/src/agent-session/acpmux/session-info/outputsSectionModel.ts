import { documentName, type Artifact } from "../conversation/artifactPreview";
import { latestWrittenArtifacts } from "../conversation/writtenArtifactsModel";
import { chatDocuments } from "../conversation/artifactVersions";
import { renderPages } from "../conversation/renderCall";
import type { AcpmuxRow } from "../model";

/// Rows shown before Show more. A fold that would hold back one row shows it instead: "Show 1 more"
/// costs the row it saves (Lucas, 2026-11-05, Session Info lab: "output should be fold at 5").
export const OUTPUTS_SHOWN = 5;
const LINK = /https?:\/\/[^\s"'<>)\]`]+/g;
const PULL_REQUEST = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/;

export type OutputLink = { readonly url: string; readonly label: string };
/// A document the chat produced, by its title when it has one.
export type OutputArtifact = {
  readonly key: string;
  readonly title?: string;
  readonly artifact: Artifact;
};

/// The chat's artifacts, oldest first: each render card's latest page (renderCall.ts `renderPages`;
/// its title, else its page's), then each document its finished replies drew, each text once.
export function outputArtifacts(rows: readonly AcpmuxRow[]): OutputArtifact[] {
  const found: OutputArtifact[] = [];
  const seen = new Set<string>();
  for (const page of new Set(renderPages(rows).values())) {
    const call = page.calls.at(-1)!;
    const artifact: Artifact = {
      kind: "html",
      lang: "html",
      code: call.html,
      render: page.first,
    };
    seen.add(call.html);
    found.push({
      key: `render:${page.first}`,
      title: call.title || documentName(artifact) || undefined,
      artifact,
    });
  }
  const replies = rows.flatMap((row) => (row.kind === "assistant" && !row.streaming && row.text ? [row.text] : []));
  for (const artifact of chatDocuments(replies)) {
    if (seen.has(artifact.code)) continue;
    seen.add(artifact.code);
    found.push({
      key: `document:${found.length}`,
      title: documentName(artifact) || undefined,
      artifact,
    });
  }
  // Each file once, as its last completed write (not the last row that wrote it).
  for (const [path, { artifact }] of latestWrittenArtifacts(rows))
    found.push({
      key: `file:${path}`,
      title: documentName(artifact) || path.split("/").pop(),
      artifact,
    });
  return found;
}

/// Each reply's links, kept while the row is the same object (a streamed update replaces only the
/// live row).
const rowLinks = new WeakMap<AcpmuxRow, string[]>();

/// The web links the chat's replies gave, oldest first, each once; pull requests are left out.
export function outputLinks(rows: readonly AcpmuxRow[]): OutputLink[] {
  const seen = new Set<string>();
  const links: OutputLink[] = [];
  for (const row of rows) {
    if (row.kind !== "assistant" || !row.text) continue;
    let found = rowLinks.get(row);
    if (!found) rowLinks.set(row, (found = [...row.text.matchAll(LINK)].map(([url]) => url.replace(/[.,;:!?]+$/, ""))));
    for (const url of found) {
      if (seen.has(url) || PULL_REQUEST.test(url)) continue;
      seen.add(url);
      links.push({
        url,
        label: url.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, ""),
      });
    }
  }
  return links;
}

/// A page the pane beside the chat can open: http(s) on localhost or 127.0.0.1 with no user info,
/// the rule the host's preview applies (URL+AgentPanePreview.swift).
export function opensBeside(url: string): boolean {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
    if (parsed.username || parsed.password) return false;
    return parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1";
  } catch {
    return false;
  }
}
