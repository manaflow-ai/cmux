// Session Info's Outputs: the files a chat made for the person, never its code edits (the Changes row
// has those). The Codex app's rule (ChatGPT.app 26.1029, its turn outputs: Lucas, 2026-11-06 "build
// codex rule"):
// - A document the replies point to: pdf, docx, pptx, xlsx, tex, as a Markdown link or as a path in
//   inline code (`/tmp/hello-pdf/hello-world.pdf`), which the pane draws as the same file chip
//   (chips/paths.ts `codePath`), or as a bare name (`test-file.pdf`), the chat's folder's. A shell
//   command that wrote a PDF in /tmp counts, since the reply points the person at it; a command in
//   inline code (`open /tmp/a.pdf`) is no path.
// - A file the host says is gone (made, then deleted) drops off (SessionInfo.tsx, useMissingPaths).
// - A file the agent created with its file tools whose kind is a deliverable: those documents, and
//   doc, ppt, xls, xlsm, csv, tsv, md, mdx and images.
// Code files never count, however they were made. Images and documents drawn in the chat itself are
// OutputsSection's own rows (the gallery, the artifacts).
import { turnFiles, type TurnFile } from "../diff";
import { codePath, linkPath } from "../chips/paths";
import type { AcpmuxRow } from "../model";
import { homePath } from "../sessionList";

/// What a reply's link makes an output: a document.
const LINKED = new Set(["docx", "pdf", "pptx", "tex", "xlsx"]);
/// What a created file makes an output: a document, a sheet, notes or an image.
const DELIVERABLE = new Set([
  ...LINKED,
  "avif",
  "csv",
  "doc",
  "gif",
  "jpeg",
  "jpg",
  "md",
  "mdx",
  "png",
  "ppt",
  "tsv",
  "webp",
  "xls",
  "xlsm",
]);

/// One output file: its path, as the host opens it, and the path to show.
export type OutputFile = { path: string; displayPath: string };

const extension = (path: string) => {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
};

/// `path` from the chat's folder when it is relative; `~` paths stay as written (the host expands them).
const absolute = (path: string, cwd: string | undefined) =>
  path.startsWith("/") || path.startsWith("~") || !cwd
    ? path
    : `${cwd.replace(/\/+$/, "")}/${path.replace(/^\.\//, "")}`;

/// The path shown: from the chat's folder when it is inside it, else from home.
function shown(path: string, cwd: string | undefined): string {
  const top = cwd?.replace(/\/+$/, "");
  if (top && path.startsWith(`${top}/`)) return path.slice(top.length + 1);
  return homePath(path);
}

/// The paths `text` points to, outside fenced code blocks: its Markdown links' and its inline code
/// paths.
function pointedPaths(text: string): string[] {
  const targets: string[] = [];
  let fenced = false;
  for (const line of text.split("\n")) {
    if (/^\s{0,3}(```|~~~)/.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    for (const match of line.matchAll(/\[[^\]\n]*\]\(([^)\s]+)\)/g)) {
      const path = linkPath(match[1]!);
      if (path) targets.push(path);
    }
    for (const match of line.matchAll(/`([^`\n]+)`/g)) {
      const code = match[1]!.trim();
      // A bare file name (`test-file.pdf`) is the chat's folder's, as the reply means it.
      const path = codePath(code) ?? (/^[\w@+-][\w.@+-]*\.[A-Za-z0-9]{1,8}$/.test(code) ? code : undefined);
      if (path) targets.push(path);
    }
  }
  return targets;
}

/// The chat's output files, oldest first, each once: the documents its replies link to, then the
/// deliverables its file tools created.
export function chatOutputs(
  rows: readonly AcpmuxRow[],
  cwd: string | undefined,
  created: readonly TurnFile[] = turnFiles([...rows]),
): OutputFile[] {
  const seen = new Set<string>();
  const out: OutputFile[] = [];
  const add = (path: string) => {
    if (seen.has(path)) return;
    seen.add(path);
    out.push({ path, displayPath: shown(path, cwd) });
  };
  for (const row of rows) {
    if (row.kind !== "assistant" || !row.text) continue;
    for (const path of pointedPaths(row.text)) if (LINKED.has(extension(path))) add(absolute(path, cwd));
  }
  for (const file of created)
    if (file.created && !file.deleted && DELIVERABLE.has(extension(file.path))) add(absolute(file.path, cwd));
  return out;
}
