// The files another agent's message names (IncomingMessageCard.tsx), written the way that agent
// writes them: a full path (`/tmp/lane/before.png`), one from home, one from the folder it works
// in (`webviews/src/a.ts`, `./notes.md`), or a bare file name after a full path in the same message
// ("Screenshots: /tmp/lane/before.png, after.png"). The reply chips know only full paths and paths
// from this chat's own folder, so each of these is written out in full before the message is
// drawn: a bare name from the folder of the full path before it, else from the sender's folder;
// a relative path from the sender's folder. The chips and thumbnails then draw them as they draw
// any path (chips/LinkChips.tsx, Markdown.tsx `proseImages`), and the host checks every one again.
// A bare name takes a full path's folder only when it is the same kind of file (an image after an
// image, a `.md` after a `.md`): "Shot: /tmp/x/a.png. Updated CHANGELOG.md" names the agent's
// CHANGELOG, not /tmp/x's. A name with nothing to start from stays as written, and so does code, a
// link, a URL and a fenced block. Each name keeps the agent's spelling (`messageFiles` `written`):
// a chip that draws as text (a missing file, a denied one) shows what the agent wrote, never a
// full path it guessed. The images among them draw as a strip of thumbnails under the message's
// text (`messageImages`), which its six-line cut never hides.
import { codePath, isImagePath } from "../chips/paths";
import { proseImages, type ThumbItem } from "./inlineMedia";

/// File types a bare name (`after.png`, `notes.md`) is taken for: pictures, video, documents and
/// logs, which an agent names next to the full path of the folder they are in. Source files
/// (`model.ts`) are left as written: an agent names those from anywhere in its repository, and
/// `Node.js` is a word.
const BARE_EXTENSIONS = "png|jpe?g|gif|webp|heic|svg|pdf|mov|mp4|webm|md|txt|log|json|jsonl|csv|html?|diff|patch";
/// File types a relative path with a folder (`webviews/src/model.ts`) is taken for.
const RELATIVE_EXTENSIONS = `${BARE_EXTENSIONS}|ya?ml|toml|tsx?|jsx?|mjs|cjs|css|swift|rs|py|sh|go|rb|xcstrings|plist`;

// Groups: a full or home path (it starts the folder the bare names after it are in); a `./` or
// `../` path; a relative path with a folder, its first folder without a dot (`example.com/a.md` is
// an address); a bare file name, starting with a letter or digit. None starts inside a word, a
// path, an address, a reference (`owner/repo@abc.md`), an option (`--out=a.png`), a variable or a
// Windows path (`C:\Users\a.png`), and none ends inside one; sentence punctuation after it stays text.
const MENTION = new RegExp(
  String.raw`(?<![\w/\\.:~@#+=$%-])(?:` +
    String.raw`(~?\/(?:[\w.@+-]+\/)*[\w.@+-]*)` +
    String.raw`|(\.{1,2}\/(?:[\w.@+-]+\/)*[\w@+-][\w.@+-]*\.(?:${RELATIVE_EXTENSIONS})(?::\d+(?::\d+)?)?)` +
    String.raw`|(\.?\w[\w@+-]*\/(?:[\w.@+-]+\/)*[\w@+-][\w.@+-]*\.(?:${RELATIVE_EXTENSIONS})(?::\d+(?::\d+)?)?)` +
    String.raw`|(\w[\w.@+-]*\.(?:${BARE_EXTENSIONS}))` +
    String.raw`)(?![\w/\\@+-]|\.\w)`,
  "gi",
);
/// A letter or digit outside ASCII (`ü`, `ï`): a name next to one is part of a word. Checked
/// around each match rather than in `MENTION`, which the `u` flag makes many times slower.
const WORD_CHAR = /[\p{L}\p{N}]/u;
/// A run of text without a space longer than this is no file name (and would make `MENTION` slow).
const LONGEST_WORD = 512;
const LONG_WORD = new RegExp(String.raw`(\S{${LONGEST_WORD + 1},})`);

// What is never prose: a code span (its whole text may be a name, groups 1 and 2), a Markdown link
// or image (group 3, its target), a reference link (`[shot.png][1]`), and a URL (its scheme starts
// a word, so a long run of letters is read once).
const SPANS =
  /(`+)([^`\n]*?)\1|!?\[[^\]\n]*\]\(((?:[^()\s]|\([^()\s]*\))+)\)|!?\[[^\]\n]*\]\[[^\]\n]*\]|(?<![\w+.-])[a-z][\w+.-]*:\/\/[^\s<>()"'`]+/gi;

/// A message's text with every file it names written as a full path, and what the agent wrote for
/// each (`written`, keyed by the full path as written out, line suffix and all).
export type MessageFiles = { text: string; written: ReadonlyMap<string, string> };

/// `text` with every file it names written as a full path: bare names and relative paths from
/// the folder of the full path before them, else from `cwd`, the sender's folder (undefined when
/// unknown).
export function messageFiles(text: string, cwd: string | undefined): MessageFiles {
  const written = new Map<string, string>();
  if (!text.includes(".")) return { text, written };
  const state: Folder = { base: undefined, kind: undefined, cwd: folderOf(cwd), written, explicit: new Set() };
  let fenced = false;
  const out = text
    .split("\n")
    .map((line) => {
      if (/^\s{0,3}(?:```|~~~)/.test(line)) {
        fenced = !fenced;
        return line;
      }
      return fenced ? line : messageLine(line, state);
    })
    .join("\n");
  return { text: out, written };
}

/// `messageFiles`' text alone.
export function messageFileText(text: string, cwd: string | undefined): string {
  return messageFiles(text, cwd).text;
}

/// Where a name starts from: the folder of the last full path (`base`) and the kind of file it
/// named (`kind`, undefined for a folder: any kind), and the sender's own folder. `written` records
/// each name written out.
type Folder = {
  base: string | undefined;
  kind: string | undefined;
  cwd: string | undefined;
  written: Map<string, string>;
  /// Full paths the agent wrote itself: the first spelling of a file is the one its chip falls back to.
  explicit: Set<string>;
};

function messageLine(line: string, state: Folder): string {
  let out = "";
  let at = 0;
  for (const span of line.matchAll(SPANS)) {
    out += prose(line.slice(at, span.index), state);
    const whole = span[0];
    if (span[1] !== undefined) {
      // A code span that is one name: written out in full, still code (Markdown.tsx `codePath`).
      const inner = span[2]!;
      const written = inner.trim();
      const full = written && written.length <= LONGEST_WORD ? fullMention(written, state) : undefined;
      out += full ? `${span[1]}${inner.replace(written, () => full)}${span[1]}` : whole;
    } else {
      // A link's or image's target, and a file URL, start the folder of what follows; never rewritten.
      const target = span[3] ?? whole;
      const path = /^file:\/\//i.test(target) ? safePath(target) : target;
      if (path && !path.startsWith("//")) startsFolder(path, state);
      out += whole;
    }
    at = span.index! + whole.length;
  }
  return out + prose(line.slice(at), state);
}

/// Plain text with its relative and bare names written out in full. A long run without a space
/// is left as it is.
function prose(text: string, state: Folder): string {
  if (!text) return text;
  if (text.length > LONGEST_WORD && LONG_WORD.test(text))
    return text
      .split(LONG_WORD)
      .map((part, index) => (index % 2 ? part : prose(part, state)))
      .join("");
  return text.replace(
    MENTION,
    (match, full?: string, dotted?: string, relative?: string, bare?: string, at?: number) => {
      if (WORD_CHAR.test(text[at! - 1] ?? "") || WORD_CHAR.test(text[at! + match.length] ?? "")) return match;
      if (full) {
        startsFolder(full, state);
        claim(full, state);
        return match;
      }
      return writeOut(match, nameFolder(Boolean(bare), match, state), state);
    },
  );
}

/// The folder a relative (`bare` false) or bare name is in: a bare name's is the last full path's
/// when it is the same kind of file, else the sender's.
function nameFolder(bare: boolean, name: string, state: Folder): string | undefined {
  if (!bare) return state.cwd;
  return state.base && (state.kind === undefined || state.kind === fileKind(name)) ? state.base : state.cwd;
}

/// `name` written out in `folder`, recorded with the agent's spelling; as written without one.
function writeOut(name: string, folder: string | undefined, state: Folder): string {
  if (!folder) return name;
  const full = joinPath(folder, name);
  if (!state.written.has(full) && !state.explicit.has(full)) state.written.set(full, name);
  return full;
}

/// What kind of file a name is, for a bare name after a full path: an image, a video, else its
/// extension.
function fileKind(name: string): string | undefined {
  const extension = /\.([A-Za-z0-9]{1,12})(?::\d+(?::\d+)?)?$/.exec(name)?.[1]?.toLowerCase();
  if (!extension) return undefined;
  if (/^(?:png|jpe?g|gif|webp|heic|svg)$/.test(extension)) return "image";
  if (/^(?:mov|mp4|webm)$/.test(extension)) return "video";
  return extension;
}

/// One name a code span holds, written out in full, or undefined when it is not one.
function fullMention(written: string, state: Folder): string | undefined {
  MENTION.lastIndex = 0;
  const match = MENTION.exec(written);
  MENTION.lastIndex = 0;
  if (!match || match.index !== 0 || match[0].length !== written.length) return undefined;
  if (match[1]) {
    startsFolder(written, state);
    claim(written, state);
    return undefined;
  }
  const from = nameFolder(Boolean(match[4]), written, state);
  return from ? writeOut(written, from, state) : undefined;
}

/// A full path names the folder the bare names after it are in, when it names a file or a folder
/// (`/tmp/a.png`, `/tmp/x/`; not `/usr` or `and / or`). Sentence punctuation after it is not part of it.
function startsFolder(written: string, state: Folder): void {
  const path = written.replace(/[.,;:!?]+$/, "");
  if (!/^(?:~|\/)/.test(path) || !(/\.[A-Za-z0-9]{1,12}$/.test(path) || path.endsWith("/"))) return;
  const parent = parentOf(path);
  if (!parent) return;
  state.base = parent;
  state.kind = path.endsWith("/") ? undefined : fileKind(path);
}

/// The folder a full path is in, or the path itself when it is a folder (`/tmp/x/`).
function parentOf(path: string): string | undefined {
  if (path.endsWith("/")) return folderOf(path);
  const cut = path.lastIndexOf("/");
  return cut > 0 ? path.slice(0, cut) : undefined;
}

/// An absolute or home folder without its trailing slash; undefined for anything else.
function folderOf(folder: string | undefined): string | undefined {
  const trimmed = folder?.trim().replace(/\/+$/, "");
  return trimmed && /^(?:~$|~\/|\/)/.test(trimmed) ? trimmed : undefined;
}

/// A full path the agent wrote, unless a name was written out to it before.
function claim(written: string, state: Folder): void {
  const path = written.replace(/[.,;:!?]+$/, "");
  if (!state.written.has(path)) state.explicit.add(path);
}

/// `name` (relative, `./` or `../` allowed) inside `folder`, with `.` and `..` resolved; a line
/// suffix stays.
export function joinPath(folder: string, name: string): string {
  const parts = folder.split("/");
  for (const part of name.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (parts.length > 1 && parts.at(-1) !== "~") parts.pop();
      continue;
    }
    parts.push(part);
  }
  return parts.join("/") || "/";
}

function safePath(url: string): string | undefined {
  try {
    return decodeURIComponent(new URL(url).pathname);
  } catch {
    return undefined;
  }
}

/// The images a message names, each once in reading order: image paths and https image addresses
/// in its prose and in code spans that are one path, not in a fenced block or a link's text.
export function messageImages(text: string): ThumbItem[] {
  if (!text.includes("/")) return [];
  let fenced = false;
  const prose = text
    .split("\n")
    .map((line) => {
      if (/^\s{0,3}(?:```|~~~)/.test(line)) {
        fenced = !fenced;
        return "";
      }
      if (fenced) return "";
      // A code span that is one image path is that path, written as prose.
      return line.replace(/(`+)([^`\n]*?)\1/g, (span, _ticks: string, inner: string) => {
        const path = codePath(inner);
        return path && isImagePath(path) ? ` ${inner.trim()} ` : span;
      });
    })
    .join("\n");
  return proseImages(prose);
}

/// The strip's thumbnails (`.cv-received__pics`, conversation.css): their size and the gaps.
export const MESSAGE_THUMB = { width: 160, height: 100, gap: 8 } as const;

/// The strip's height for `count` images across `width` px of the card's text (model.ts estimates).
export function messageImagesHeight(count: number, width: number): number {
  if (count === 0) return 0;
  const { width: thumb, height, gap } = MESSAGE_THUMB;
  const across = Math.max(1, Math.floor((width + gap) / (thumb + gap)));
  const rows = Math.ceil(count / across);
  return gap + rows * height + (rows - 1) * gap;
}
