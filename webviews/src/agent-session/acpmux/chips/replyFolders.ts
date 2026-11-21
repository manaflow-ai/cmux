// The folders a reply's own paths are in, for its bare file names (Leo 2026-10-22, of a reply that
// linked `chromium-base-see-through.png` and then named `chromium-fixed-see-through.png` and
// `chromium-fixed-opaque.png` as plain text beside it: "can you just enable all these"). A name with
// no folder is a chip only when the host says that file is in one of these folders; otherwise it
// stays as written, so `Next.js` or `config.json` in prose never turns into a chip.
import { createContext, useContext } from "react";
import { codePath, isPathShape, linkPath, textLinks } from "./paths";

/// At most this many folders are asked about for each bare name.
export const MAX_REPLY_FOLDERS = 4;

const NONE: readonly string[] = [];

export const ReplyFoldersContext = createContext<readonly string[]>(NONE);

/// The folders the reply being drawn names (empty outside a reply).
export function useReplyFolders(): readonly string[] {
  return useContext(ReplyFoldersContext);
}

const MARKDOWN_LINK = /\]\(([^()\s]+)\)/g;
const CODE_SPAN = /`([^`\n]+)`/g;

/// The folders of every path `source` names, in reading order: Markdown links, code spans and
/// prose. A folder path is its own folder. Relative paths stay relative (the host resolves them
/// from the session's folder, as it does for their chips).
export function replyFolders(source: string): readonly string[] {
  if (!source.includes("/")) return NONE;
  const found: { at: number; path: string }[] = [];
  for (const match of source.matchAll(MARKDOWN_LINK)) {
    const path = linkPath(match[1]!);
    if (path && isPathShape(path)) found.push({ at: match.index!, path });
  }
  for (const match of source.matchAll(CODE_SPAN)) {
    const path = codePath(match[1]!);
    if (path) found.push({ at: match.index!, path });
  }
  for (const link of textLinks(source))
    if (link.kind === "path" && link.path && isPathShape(link.path)) found.push({ at: link.start, path: link.path });
  const folders: string[] = [];
  for (const { path } of found.sort((a, b) => a.at - b.at)) {
    const folder = path.endsWith("/") ? path : path.slice(0, path.lastIndexOf("/") + 1);
    if (folder && !folders.includes(folder)) folders.push(folder);
    if (folders.length === MAX_REPLY_FOLDERS) break;
  }
  return folders.length ? folders : NONE;
}

/// replyFolders for a text that grows at its end (a streaming reply, revealed a frame at a time).
/// No path, link or code span the scan reads crosses a line break, so the folders of a text are its
/// complete lines' folders, then its last line's, in order: complete lines are scanned once, as they
/// complete, and only the line still arriving is scanned again. Once MAX_REPLY_FOLDERS are found in
/// complete lines nothing more is scanned. A text that is not the last one grown starts over.
export class ReplyFolderScan {
  private source = "";
  /// Where the complete lines end (after the last line break scanned).
  private done = 0;
  private settled: string[] = [];
  private folders: readonly string[] = NONE;
  // perf-hot: O(new text) per reveal frame chat-100k-flat
  update(source: string): readonly string[] {
    if (source === this.source) return this.folders;
    if (!(source.length > this.source.length && source.startsWith(this.source))) {
      this.done = 0;
      this.settled = [];
    }
    this.source = source;
    if (this.settled.length < MAX_REPLY_FOLDERS) {
      const end = source.lastIndexOf("\n") + 1;
      if (end > this.done) {
        for (const folder of replyFolders(source.slice(this.done, end)))
          if (this.settled.length < MAX_REPLY_FOLDERS && !this.settled.includes(folder)) this.settled.push(folder);
        this.done = end;
      }
    }
    const all = [...this.settled];
    if (all.length < MAX_REPLY_FOLDERS)
      for (const folder of replyFolders(source.slice(this.done)))
        if (all.length < MAX_REPLY_FOLDERS && !all.includes(folder)) all.push(folder);
    this.folders = all.length ? all : NONE;
    return this.folders;
  }
}

/// A file name with no folder, as an agent writes one: a name and an extension of letters and
/// digits (`chromium-fixed-opaque.png`, `notes_v2.md`). Not a version (`4.5`), a host
/// (`example.com` has no file extension we know of below) or a sentence's last word.
const NAME = String.raw`[\w@+-][\w.@+-]*\.(?:png|jpe?g|gif|webp|svg|heic|mp4|mov|webm|m4a|mp3|wav|pdf|html?|txt|log|md|json|jsonl|csv|tsv|ya?ml|toml|xml|zip|gz|tgz|tar|dmg|ipa|crash|ips|trace|diff|patch|swift|ts|tsx|js|jsx|mjs|css|rs|py|sh|go|rb|cc|cpp|hpp|mm|zig|sql|plist|xcstrings|strings)`;
const BARE_NAME = new RegExp(String.raw`(?<![\w/.:~@+-])${NAME}(?![\w/@+-]|\.\w|:\d)`, "gi");
const WHOLE_NAME = new RegExp(String.raw`^${NAME}$`, "i");

/// Every bare file name in plain text, with where it is.
export function bareFileNames(text: string): { start: number; end: number; name: string }[] {
  if (!text.includes(".")) return [];
  return [...text.matchAll(BARE_NAME)].map((match) => ({
    start: match.index!,
    end: match.index! + match[0].length,
    name: match[0],
  }));
}

/// Whether a code span's text is one bare file name.
export function isBareFileName(text: string): boolean {
  return WHOLE_NAME.test(text);
}
