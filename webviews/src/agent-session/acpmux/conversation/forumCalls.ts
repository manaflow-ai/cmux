// A call to the cmux-forum MCP server's post, reply or search tool (cmux-tui acpmux forum_mcp.rs),
// read into what ForumCallCard draws: the thread's title, space, reply count and a link into it, or
// a search's hits. Leo, 2026-11-22: "i wonder if that's also grounds for a new type of tool call
// appearance in the gui". The server answers with one JSON object as its result text:
//   {"forum":"post","thread":{number,title,space,state,comments,url}}
//   {"forum":"reply","thread":{...},"comment":{"id":N}}
//   {"forum":"search","query":"...","hits":[{number,title,space,state,comments,snippet}]}
// Claude names the call `mcp__cmux-forum__post`, Codex nests it as {server, tool, arguments}, and a
// title may read `cmux-forum.post`. The server's other tools (announce, rules, ack) are not these:
// they keep their MCP rows.
import type { AcpmuxActivity } from "../model";
import { safeHref } from "../replyHref";
import type { McpCall } from "./mcpCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type ForumTool = "post" | "reply" | "search";

export type ForumThreadRef = {
  number?: number;
  title?: string;
  space?: string;
  state?: string;
  comments?: number;
  /// An https link into the thread, when the forum gave one.
  url?: string;
  snippet?: string;
};

export type ForumCall = {
  tool: ForumTool;
  status: "running" | "done" | "failed";
  /// post: the thread made; reply: the thread replied on. From the result once there, else from
  /// the call's arguments.
  thread?: ForumThreadRef;
  /// The text the agent posted or replied with (the arguments' body).
  body?: string;
  query?: string;
  hits: ForumThreadRef[];
  /// A failed call's first line of error text.
  error?: string;
};

const SERVER = /^cmux[-_]forum$/i;
const TOOLS: Record<string, ForumTool> = { post: "post", reply: "reply", search: "search" };
const DOTTED = /^cmux[-_]forum[.:](post|reply|search)\b/i;
const MAX_HITS = 10;

/// The forum call `tool` made, or nil for any other call. `named` is its parsed MCP name, when it
/// has one (mcpCalls.ts `mcpCall`).
export function forumCall(tool: Tool, named: McpCall | undefined): ForumCall | undefined {
  let which: ForumTool | undefined;
  let args: unknown;
  if (named) {
    if (!SERVER.test(named.server)) return undefined;
    which = TOOLS[named.tool.toLowerCase()];
    args = named.args;
  } else {
    const dotted = DOTTED.exec(tool.title.trim());
    if (!dotted) return undefined;
    which = TOOLS[dotted[1]!.toLowerCase()];
    args = parseJSON(tool.inputSummary);
  }
  if (!which) return undefined;
  const input = isRecord(args) ? args : {};
  const running = tool.status === "pending" || tool.status === "in_progress";
  const result = running ? undefined : findResult(parseJSON(tool.output), which, 0);
  // A finished call whose result is not the forum's answer (a server older than this card) keeps
  // its plain MCP row.
  if (!running && tool.status !== "failed" && !result) return undefined;
  const failed = !running && !result;
  const call: ForumCall = {
    tool: which,
    status: running ? "running" : failed ? "failed" : "done",
    body: str(input.body),
    query: str(result?.query) ?? str(input.query),
    hits: [],
  };
  if (which === "search") {
    call.hits = (Array.isArray(result?.hits) ? result.hits : []).filter(isRecord).slice(0, MAX_HITS).map(threadOf);
  } else {
    const fromResult = isRecord(result?.thread) ? threadOf(result.thread) : undefined;
    call.thread = fromResult ?? {
      number: num(input.thread),
      title: str(input.title),
      space: str(input.space),
    };
  }
  if (call.status === "failed") call.error = errorLine(tool.output);
  return call;
}

/// The result object anywhere in `value`: itself, an MCP result's text block or structured content,
/// a few levels down.
function findResult(value: unknown, which: ForumTool, depth: number): Record<string, unknown> | undefined {
  if (depth > 4 || value === undefined || value === null) return undefined;
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed.startsWith("{") || trimmed.startsWith("[")
      ? findResult(parseJSON(trimmed), which, depth + 1)
      : undefined;
  }
  if (Array.isArray(value)) {
    for (const entry of value) {
      const found = findResult(entry, which, depth + 1);
      if (found) return found;
    }
    return undefined;
  }
  if (!isRecord(value)) return undefined;
  if (value.isError === true) return undefined;
  if (value.forum === which) return value;
  for (const key of ["structuredContent", "result", "content", "text", "output"]) {
    const found = findResult(value[key], which, depth + 1);
    if (found) return found;
  }
  return undefined;
}

function threadOf(raw: Record<string, unknown>): ForumThreadRef {
  // Tool output is untrusted: only an https link is drawn.
  const href = typeof raw.url === "string" ? safeHref(raw.url) : undefined;
  return {
    number: num(raw.number),
    title: str(raw.title),
    space: str(raw.space),
    state: str(raw.state),
    comments: typeof raw.comments === "number" && Number.isFinite(raw.comments) ? raw.comments : undefined,
    url: href?.startsWith("https://") ? href : undefined,
    snippet: str(raw.snippet),
  };
}

/// The first line of a failed call's text: the server's own message ("The hosted forum is not set
/// up on this machine ...").
function errorLine(output: string | undefined): string | undefined {
  const texts: string[] = [];
  const collect = (value: unknown, depth: number) => {
    if (depth > 4 || texts.length) return;
    if (typeof value === "string") {
      const parsed = parseJSON(value);
      if (parsed !== value) return collect(parsed, depth + 1);
      if (value.trim()) texts.push(value.trim());
      return;
    }
    if (Array.isArray(value)) return value.forEach((entry) => collect(entry, depth + 1));
    if (isRecord(value)) for (const key of ["content", "text", "error", "message"]) collect(value[key], depth + 1);
  };
  collect(output, 0);
  const line = texts[0]?.split("\n")[0]?.trim();
  return line ? line.slice(0, 200) : undefined;
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function num(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJSON(text: string | undefined): unknown {
  if (!text) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}
