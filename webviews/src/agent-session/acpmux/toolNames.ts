// l10n-allow-file: harness tool names and the English verbs acpmux already titles Claude Code's calls with.
// One tool, one look, whichever harness ran it: each harness's own names for its built-in tools, and
// the title and input shapes they reach the page in, read as one canonical tool and its input
// (`canonicalCall`), so a Gemini `read_file` reads "Read foo.ts" as a Claude Code Read does. What
// each harness sends, from its ACP adapter (gap sweep 2026-11-05, harness-render-contracts.md § 9):
//   Claude Code  acpmux titles the call (claude_stdio/mod.rs `tool_title`): "Read <file>",
//                "Grep <pattern>", "Glob <pattern>", "Fetch <url>", "Search <query>", the command, and
//                the input as sent ({file_path}, {pattern, path}, {url}, {query}, {command}). Grep and
//                Glob come with kind "read", WebSearch with "fetch".
//   Codex        cmux-codex-acp titles a parsed command "Read <file>", "Search <query>", "List <dir>"
//                (kinds read, search, search), a web search "Search <query>" or "Web search" (fetch),
//                a file change "Write|Edit|Delete <file>"; the input is {command, cwd, commandLine}.
//   Gemini CLI   no input at all; the title is the call's description (packages/core tools): read_file
//                "src/foo.ts" (read, with its location), grep_search "'pat' within dir" and glob
//                "'pat' within dir" (search), list_directory "dir" (search), web_fetch "Fetching
//                content from: <url>" (fetch), google_web_search `Searching the web for: "q"`
//                (search), write_file "Writing to <path>" and replace "<path>: old => new" (edit).
//   opencode     the tool's name ("read", "grep", "webfetch") until it runs, then its own short title
//                (a file name for a read); the input as sent ({filePath} or {path}, {pattern, path},
//                {url}, {query}, {command}).
//   pi           the tool's name: read/edit/write {path}, grep {pattern, path}, find {pattern}, ls {path}.
//   Muse         "<name>: <subject>" ("read_file: src/parser.rs").
import type { AcpmuxActivity } from "./model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// What a call does, whatever its harness named it.
export type CanonicalTool =
  | "read"
  | "search"
  | "glob"
  | "list"
  | "fetch"
  | "websearch"
  | "shell"
  | "edit"
  | "write"
  | "todo"
  | "task";

/// A call's input, in one spelling: the file it reads or changes, the pattern it searches for, the
/// page it fetches, the words it searches the web for, the command it runs. Only what it said.
export type CanonicalInput = { path?: string; pattern?: string; url?: string; query?: string; command?: string };

export type CanonicalCall = { tool: CanonicalTool; input: CanonicalInput };

export type Harness = "claude" | "codex" | "gemini" | "opencode" | "pi" | "muse";

/// Each harness's names for its built-in tools. A name reads case-blind (`toolForName`).
export const HARNESS_TOOL_NAMES: Record<Harness, Record<string, CanonicalTool>> = {
  claude: {
    Read: "read",
    NotebookRead: "read",
    Grep: "search",
    Glob: "glob",
    WebFetch: "fetch",
    Fetch: "fetch",
    WebSearch: "websearch",
    Bash: "shell",
    Edit: "edit",
    MultiEdit: "edit",
    NotebookEdit: "edit",
    Write: "write",
    TodoWrite: "todo",
    Task: "task",
    Agent: "task",
  },
  codex: {
    Read: "read",
    Search: "search",
    List: "list",
    shell: "shell",
    local_shell: "shell",
    exec_command: "shell",
    apply_patch: "edit",
    Edit: "edit",
    Write: "write",
    read_file: "read",
    web_search: "websearch",
    update_plan: "todo",
  },
  gemini: {
    read_file: "read",
    read_many_files: "read",
    grep_search: "search",
    search_file_content: "search",
    glob: "glob",
    list_directory: "list",
    web_fetch: "fetch",
    google_web_search: "websearch",
    run_shell_command: "shell",
    replace: "edit",
    write_file: "write",
    write_todos: "todo",
  },
  opencode: {
    read: "read",
    grep: "search",
    glob: "glob",
    list: "list",
    webfetch: "fetch",
    websearch: "websearch",
    bash: "shell",
    shell: "shell",
    edit: "edit",
    multiedit: "edit",
    patch: "edit",
    write: "write",
    todowrite: "todo",
    task: "task",
    subagent: "task",
  },
  pi: { read: "read", grep: "search", find: "glob", ls: "list", bash: "shell", edit: "edit", write: "write" },
  muse: { read_file: "read", write_todos: "todo" },
};

/// Every harness's names, case-blind. Two harnesses that share a name mean one tool by it.
const BY_NAME = new Map<string, CanonicalTool>(
  Object.values(HARNESS_TOOL_NAMES).flatMap((names) =>
    Object.entries(names).map(([name, tool]) => [name.toLowerCase(), tool] as const),
  ),
);

/// The canonical tool a harness's name stands for, or undefined for a name no table knows.
export function toolForName(name: string): CanonicalTool | undefined {
  return BY_NAME.get(name.trim().toLowerCase());
}

/// The verb a canonical call's row starts with, as acpmux titles Claude Code's calls; a search reads
/// "Search", as Codex and plain English say it.
export const CANONICAL_VERB: Record<CanonicalTool, string> = {
  read: "Read",
  search: "Search",
  glob: "Glob",
  list: "List",
  fetch: "Fetch",
  websearch: "Search",
  shell: "Run",
  edit: "Edit",
  write: "Write",
  todo: "Update todos",
  task: "Agent",
};

/// The ACP kind a canonical tool has, so every harness's call groups, counts and draws its glyph by
/// what it did: Claude Code's Grep and Glob search (acpmux sends them as "read"), Gemini's web search
/// goes to the web (Gemini sends "search").
const CANONICAL_KIND: Partial<Record<CanonicalTool, string>> = {
  read: "read",
  search: "search",
  glob: "search",
  list: "search",
  fetch: "fetch",
  websearch: "fetch",
  shell: "execute",
  edit: "edit",
  write: "edit",
};

/// The ACP kind a call is drawn by: its canonical tool's, else the kind its harness sent.
export function toolKind(tool: Tool): string | undefined {
  const call = canonicalCall(tool);
  return (call && CANONICAL_KIND[call.tool]) ?? tool.kind;
}

/// Gemini CLI's descriptions, which it sends as titles.
const GEMINI_FETCH = /^Fetching content from:\s*(\S+)/;
const GEMINI_WEB_SEARCH = /^Searching the web for:\s*"(.*)"\s*$/;
const GEMINI_WRITE = /^Writing to\s+(.+)$/;
const GEMINI_PATTERN = /^'(.+?)'(?:\s+in\s+\S+)?(?:\s+within\s+.+)?$/;
const GEMINI_REPLACE = /^(.+?):\s.*=>/;

/// A call's canonical tool and input, read from its title's name and its input's shape, or undefined
/// for a call none of the harnesses' tables or shapes name (an MCP tool, a harness's own tool).
export function canonicalCall(tool: Tool): CanonicalCall | undefined {
  // A call's snapshot never changes (an update makes a new one), and groups, summaries and rows each
  // ask about it as a transcript draws.
  if (READ.has(tool)) return READ.get(tool);
  const call = readCall(tool);
  READ.set(tool, call);
  return call;
}

const READ = new WeakMap<Tool, CanonicalCall | undefined>();

function readCall(tool: Tool): CanonicalCall | undefined {
  const title = tool.title?.trim() ?? "";
  const raw = parseInput(tool.inputSummary);
  const input = inputOf(raw, tool);
  // "Read App.tsx", "read", "read_file: src/parser.rs": the title's first word names the tool.
  const head = title.split(/\s+/, 1)[0]?.replace(/:$/, "") ?? "";
  const named = toolForName(head);
  // A shell's title is its command line: `grep -rn foo`, `ls src` and `find .` ran a command, not
  // opencode's grep or pi's ls and find.
  if (tool.kind === "execute") return named === "shell" || input.command ? { tool: "shell", input } : undefined;
  if (named) {
    const rest = title.slice(title.indexOf(head) + head.length).replace(/^:?\s*/, "");
    return { tool: disambiguate(named, tool.kind), input: withTitleSubject(named, input, rest, tool.kind) };
  }
  // Gemini CLI's descriptions.
  let match: RegExpMatchArray | null;
  if ((match = title.match(GEMINI_FETCH))) return { tool: "fetch", input: { url: match[1], ...input } };
  if ((match = title.match(GEMINI_WEB_SEARCH))) return { tool: "websearch", input: { query: match[1], ...input } };
  if (tool.kind === "edit" && (match = title.match(GEMINI_WRITE)))
    return { tool: "write", input: { path: match[1]!.trim(), ...input } };
  // "<path>: old => new"; a location names the file even when its path has a space or a colon.
  if (tool.kind === "edit" && (match = title.match(GEMINI_REPLACE)))
    return { tool: "edit", input: { path: match[1], ...input } };
  if (tool.kind === "search" && (match = title.match(GEMINI_PATTERN))) {
    const pattern = match[1]!;
    return { tool: looksLikeGlob(pattern) ? "glob" : "search", input: { pattern, ...input } };
  }
  // A title that is its subject (Gemini's read_file and list_directory, opencode's finished read):
  // the kind and the input say what the call did.
  if (tool.kind === "read" && input.path) return { tool: "read", input };
  if (tool.kind === "read" && !raw && looksLikePath(title)) return { tool: "read", input: { path: title } };
  if (tool.kind === "search" && input.pattern) return { tool: looksLikeGlob(input.pattern) ? "glob" : "search", input };
  // Gemini's list_directory: its folder, which may be a bare name ("src").
  if (tool.kind === "search" && !raw && (looksLikePath(title) || /^[\w.-]+$/.test(title)))
    return { tool: "list", input: { path: title } };
  if (tool.kind === "fetch" && input.url) return { tool: "fetch", input };
  if (tool.kind === "fetch" && input.query) return { tool: "websearch", input };
  return undefined;
}

/// One name for two tools: Claude Code's and Codex's "Search" is a web search when it goes to the web.
function disambiguate(tool: CanonicalTool, kind: string | undefined): CanonicalTool {
  return tool === "search" && kind === "fetch" ? "websearch" : tool;
}

/// The input, with the subject a "<Verb> <subject>" title names where the input does not say it.
function withTitleSubject(
  tool: CanonicalTool,
  input: CanonicalInput,
  subject: string,
  kind: string | undefined,
): CanonicalInput {
  if (!subject) return input;
  switch (disambiguate(tool, kind)) {
    case "search":
    case "glob":
      return { pattern: subject, ...input };
    case "websearch":
      return { query: subject, ...input };
    case "fetch":
      return { url: subject, ...input };
    default:
      return input;
  }
}

/// The input fields the harnesses spell their own way, read as one.
function inputOf(raw: Record<string, unknown> | undefined, tool: Tool): CanonicalInput {
  const text = (...keys: string[]) => {
    for (const key of keys) {
      const value = raw?.[key];
      if (typeof value === "string" && value.trim()) return value.trim();
    }
    return undefined;
  };
  const input: CanonicalInput = {};
  const path =
    text("file_path", "filePath", "absolute_path", "notebook_path", "path", "dir_path") ??
    tool.locations?.find((location) => location.path)?.path;
  if (path) input.path = path;
  const pattern = text("pattern", "regex");
  if (pattern) input.pattern = pattern;
  const url = text("url");
  if (url) input.url = url;
  const query = text("query", "q");
  if (query) input.query = query;
  const command = tool.command?.trim();
  if (command) input.command = command;
  return input;
}

/// A file pattern rather than a text one: `**/*.ts`, `*.md`, `src/*.ts`, `src/{a,b}.ts`. A `*` opens
/// a glob only at the start or after `/` (`foo*bar`, `foo.*bar` repeat in a regex).
function looksLikeGlob(pattern: string): boolean {
  return /(?:^|\/)\*|\{[^}]*,[^}]*\}/.test(pattern);
}

/// `text` reads as one path: a folder in it, or a file name with an extension.
function looksLikePath(text: string): boolean {
  if (!text || /[\s{}"']/.test(text)) return false;
  return /\//.test(text) || /^[\w.-]+\.[A-Za-z0-9]{1,12}$/.test(text);
}

function parseInput(summary: string | undefined): Record<string, unknown> | undefined {
  if (!summary) return undefined;
  try {
    const value: unknown = JSON.parse(summary);
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}
