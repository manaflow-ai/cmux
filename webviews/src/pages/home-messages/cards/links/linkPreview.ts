// Home link chips and their preview cards, ported from Swift `HomeLinkChip` (the kind a link shows
// as), `HomeLinkPreview` and `HomeLinkChipHoverSource` (CmuxNextHome/LinkChips) and
// `HomeLinkPreviewProvider` (CmuxNextApp/Home). The facts come from the app through one host op,
// `cmux.home.linkPreview` (spec below); the swap PR wires it to the provider, which reads the
// models and never changes them.

/** What a chip points at; its icon. */
export type HomeLinkChipKind =
  | "workspace"
  | "pane"
  | "tab"
  | "terminal"
  | "browser"
  | "session"
  | "subagent"
  | "folder"
  | "markdown"
  | "image"
  | "code"
  | "file"
  | "pullRequest"
  | "issue"
  | "commit"
  | "run";

/** The cmux icon of each kind (the Swift chip's SF Symbol, in the shared pack). */
export const LINK_KIND_ICON: Record<HomeLinkChipKind, string> = {
  workspace: "workspace",
  pane: "pane.split.right",
  tab: "view.tab.trailing",
  terminal: "terminal",
  browser: "browser",
  session: "agent.chat",
  subagent: "team",
  folder: "folder",
  markdown: "file.text",
  image: "site.permission.images",
  code: "code",
  file: "file",
  pullRequest: "git.pullrequest",
  issue: "status.attention",
  commit: "git.branch",
  run: "media.play",
};

/** The tone of a preview's state word. */
export type LinkPreviewTone = "secondary" | "success" | "danger";

/** What a link chip's hover card shows: the target's live title, where it is, its state, a few
 * lines of its content and an optional picture. */
export interface HomeLinkPreview {
  kind: HomeLinkChipKind;
  title: string;
  /** Where it is: a workspace, a folder, a page's URL, a repository. */
  place?: string;
  /** A short state word ("Open", "Closed"), already localized by the host. */
  status?: string;
  statusTone?: LinkPreviewTone;
  /** Content lines: a terminal's last lines, a document's first lines, a workspace's tabs (at most 6). */
  lines?: readonly string[];
  /** The lines are code or terminal text. */
  monospaced?: boolean;
  /** A picture of the target (a browser page's thumbnail), as an image URL the page may load. */
  thumbnail?: string;
}

/**
 * `cmux.home.linkPreview` (page → host). Params `{url, kind, details}`; answers a
 * `HomeLinkPreview`.
 *  - `details: false`: what the app knows at once (titles, state), for the card as it opens
 *    (`HomeLinkPreviewing.preview(for:kind:)`).
 *  - `details: true`: the same with the slower facts (a terminal's last lines, a file's first lines,
 *    a page's thumbnail), for the card to update in place (`details(for:preview:)`).
 *  A target the app no longer has answers its id as the title, `status` "Closed", tone `danger`.
 */
export const LINK_PREVIEW_OP = "cmux.home.linkPreview";

export interface LinkPreviewParams {
  url: string;
  kind: HomeLinkChipKind;
  details: boolean;
}

export type LinkPreviewFetch = (params: LinkPreviewParams) => Promise<HomeLinkPreview | undefined>;

const TOKEN = /^[A-Za-z0-9._-]{1,200}$/;
const HEX = (count: number) => new RegExp(`^[0-9a-f]{${count}}$`);

/** A Chief subagent's chat link: `cmux://chief/<8 hex>/session/<token>`, nothing else. */
export function isChiefSubagentLink(link: string): boolean {
  const match = /^cmux:\/\/chief\/([^/?#]*)\/session\/([^/?#]*)$/.exec(link);
  return !!match && HEX(8).test(match[1]!) && TOKEN.test(match[2]!);
}

/** A cmux app link Home renders (`isCmuxAppLink`): workspace, pane, tab and session links in the
 * `cmux` scheme or a build's `cmux-…` one, with only the app's `machine=machine_…` hint. */
export function isCmuxAppLink(link: string): boolean {
  if (isChiefSubagentLink(link)) return true;
  let url: URL;
  try {
    url = new URL(link);
  } catch {
    return false;
  }
  const scheme = url.protocol.slice(0, -1).toLowerCase();
  if (scheme !== "cmux" && !scheme.startsWith("cmux-")) return false;
  if (url.username || url.password || url.port) return false;
  for (const [name, value] of url.searchParams) if (name !== "machine" || !value.startsWith("machine_")) return false;
  const host = url.hostname.toLowerCase();
  const parts = url.pathname.split("/");
  if (parts.length !== 2 || parts[0] !== "") return false;
  const id = parts[1]!;
  const fragment = url.hash.slice(1);
  const resource = (prefix: string) => id.startsWith(prefix) && !url.hash && HEX(32).test(id.slice(prefix.length));
  switch (host) {
    case "workspace":
      return resource("ws_");
    case "pane":
      return resource("pane_");
    case "tab":
      return resource("tab_");
    case "session":
      return TOKEN.test(id) && (!url.hash || (fragment.startsWith("turn-") && TOKEN.test(fragment.slice(5))));
    default:
      return false;
  }
}

/** A path an agent wrote, as Home links it: an absolute local `file://` path, no host other than
 * `localhost`, no user, port, query or fragment. */
export function isHomePathLink(link: string): boolean {
  let url: URL;
  try {
    url = new URL(link);
  } catch {
    return false;
  }
  return (
    url.protocol === "file:" &&
    !url.username &&
    !url.password &&
    !url.port &&
    !url.search &&
    !url.hash &&
    (url.hostname === "" || url.hostname === "localhost") &&
    url.pathname.startsWith("/")
  );
}

const IMAGES = new Set(["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp"]);
const SOURCES = new Set([
  "swift",
  "ts",
  "tsx",
  "js",
  "jsx",
  "rs",
  "py",
  "go",
  "json",
  "c",
  "h",
  "m",
  "mm",
  "cpp",
  "zig",
  "sh",
  "rb",
  "java",
  "kt",
  "css",
  "html",
  "yml",
  "yaml",
  "toml",
]);

/** A path part with its escapes decoded; a malformed escape (`%ZZ`) keeps the raw text. */
function decodedName(part: string): string {
  try {
    return decodeURIComponent(part);
  } catch {
    return part;
  }
}

function fileKind(link: string): HomeLinkChipKind {
  if (link.endsWith("/")) return "folder";
  const name = decodedName(new URL(link).pathname.split("/").pop() ?? "");
  const dot = name.lastIndexOf(".");
  const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
  if (!ext) return "folder";
  if (ext === "md" || ext === "markdown") return "markdown";
  if (IMAGES.has(ext)) return "image";
  if (SOURCES.has(ext)) return "code";
  return "file";
}

/** The chip `link` (a sanitized link destination) shows as, or undefined for plain link text. */
export function linkChipKind(link: string): HomeLinkChipKind | undefined {
  if (isChiefSubagentLink(link)) return "subagent";
  if (isCmuxAppLink(link)) {
    const host = new URL(link).hostname.toLowerCase();
    return host === "workspace" || host === "pane" || host === "tab" || host === "session" ? host : undefined;
  }
  if (isHomePathLink(link)) return fileKind(link);
  let url: URL;
  try {
    url = new URL(link);
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:" || url.hostname.toLowerCase() !== "github.com") return undefined;
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length < 4) return undefined;
  const number = (text: string | undefined) => !!text && /^\d+$/.test(text);
  switch (parts[2]) {
    case "pull":
      return number(parts[3]) ? "pullRequest" : undefined;
    case "issues":
      return number(parts[3]) ? "issue" : undefined;
    case "commit":
      return /^[0-9a-fA-F]{7,}$/.test(parts[3]!) ? "commit" : undefined;
    case "actions":
      return parts[3] === "runs" && number(parts[4]) ? "run" : undefined;
    default:
      return undefined;
  }
}

/** A chip's label: a short one (≤ 40 units) with no-break spaces, so it wraps as one unit. */
export function chipLabel(text: string): string {
  return text.length <= 40 ? text.replaceAll(" ", " ") : text;
}
