// What closes a completed turn, after the final answer: end resources (files the turn
// produced, or a web preview of a local server / HTML file) and the "Edited N files" card.
//
// Mirrors `Txr()` / `Dxr()` in the ChatGPT desktop bundle (app-shared-*.js):
// - files: links in the final answer to local .docx/.pdf/.tex/.pptx/.xlsx files;
// - otherwise one website: the single distinct local web URL (localhost, 127.0.0.1, 0.0.0.0,
//   ::1 or *.localhost, with an explicit port) in the final answer, else the single edited
//   .html/.htm file;
// - the edited-files card shows unless every edited file is already an end resource.
// Resources only appear once the turn completed. See docs/codex-data-model.md.
import { turnEdits, type DeriveOptions } from "./derive";
import type { Turn } from "./protocol";

export type TurnEndBlock =
  | { kind: "file"; key: string; path: string; name: string; subtitle: string }
  | { kind: "website"; key: string; target: string; title: string; subtitle: string }
  | {
      kind: "edited-files";
      key: string;
      files: { path: string; additions: number; deletions: number }[];
    };

const DOC_EXTENSIONS = new Set(["docx", "pdf", "tex", "pptx", "xlsx"]);
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "::1"]);
const URL_RE = /\bhttps?:\/\/[^\s<>)"'`]+/gi;
const LINK_RE = /!?\[([^\]]*)\]\(([^)\s]+)\)/g;

const extension = (p: string) => p.slice(p.lastIndexOf(".") + 1).toLowerCase();
const basename = (p: string) => p.slice(p.lastIndexOf("/") + 1);

const SUBTITLES: Record<string, string> = {
  pdf: "Document · pdf",
  docx: "Document · docx",
  tex: "LaTeX document · Editable source",
  pptx: "Presentation · pptx",
  xlsx: "Spreadsheet · xlsx",
};

/** `FM()` / `bbt()`: an http(s) URL on a loopback host. */
export function isLocalWebUrl(href: string): boolean {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  const host = url.hostname.toLowerCase();
  return host.endsWith(".localhost") || LOCAL_HOSTS.has(host);
}

/** `Lxr()`: the one local web URL (with a port) the answer mentions, if exactly one. */
export function singleLocalUrl(markdown: string): string | null {
  const found = new Set<string>();
  for (const m of markdown.matchAll(URL_RE)) {
    const raw = m[0].replace(/[.,;!?]+$/u, "");
    let url: URL;
    try {
      url = new URL(raw);
    } catch {
      continue;
    }
    if (/[()[\]]/u.test(`${url.pathname}${url.search}${url.hash}`) || url.port === "") continue;
    if (isLocalWebUrl(url.href)) found.add(url.href);
  }
  return found.size === 1 ? [...found][0]! : null;
}

/** Local file targets of Markdown links (absolute paths or file:// URLs). */
export function localFileLinks(markdown: string): string[] {
  const out: string[] = [];
  for (const m of markdown.matchAll(LINK_RE)) {
    if (m[0].startsWith("!")) continue;
    const dest = m[2]!;
    if (dest.startsWith("file://")) out.push(decodeURI(dest.slice("file://".length)));
    else if (dest.startsWith("/")) out.push(dest.replace(/[#:].*$/, ""));
  }
  return out;
}

export function turnEnd(turn: Turn, opts: DeriveOptions = {}): TurnEndBlock[] {
  if (turn.status !== "completed") return [];
  const answer = turn.items
    .filter((i) => i.type === "agentMessage" && i.phase === "final_answer")
    .map((i) => (i.type === "agentMessage" ? i.text : ""))
    .join("\n\n");
  const blocks: TurnEndBlock[] = [];
  const seen = new Set<string>();
  for (const path of localFileLinks(answer)) {
    const ext = extension(path);
    if (!DOC_EXTENSIONS.has(ext) || seen.has(path)) continue;
    seen.add(path);
    blocks.push({
      kind: "file",
      key: `file:${path}`,
      path,
      name: basename(path),
      subtitle: SUBTITLES[ext] ?? ext,
    });
  }
  const edits = turnEdits(turn.items, opts.cwd);
  if (blocks.length === 0) {
    const url = singleLocalUrl(answer);
    const html = turn.items
      .flatMap((i) => (i.type === "fileChange" ? i.changes.map((c) => c.path) : []))
      .filter((p, i, all) => /\.html?$/i.test(p) && all.indexOf(p) === i);
    const target = url ?? (html.length === 1 ? html[0]! : null);
    if (target)
      blocks.push({
        kind: "website",
        key: `website:${target}`,
        target,
        title: "Web preview",
        subtitle: "Website",
      });
  }
  // Hidden when every edited file is already shown as a resource (`Dxr()`).
  const covered = new Set(
    blocks.flatMap((b) => (b.kind === "file" ? [b.path] : b.kind === "website" ? [b.target] : [])),
  );
  const editedAbs = turn.items.flatMap((i) =>
    i.type === "fileChange" ? i.changes.map((c) => c.path) : [],
  );
  if (edits.length > 0 && !editedAbs.every((p) => covered.has(p)))
    blocks.push({ kind: "edited-files", key: `edited:${turn.id}`, files: edits });
  return blocks;
}
