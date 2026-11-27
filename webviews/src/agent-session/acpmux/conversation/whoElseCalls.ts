// "Who else is working on these files": acpmux's answer (`_acpmux/who_else`, schema
// `acpmux.who-else.v1`) as a tool call carries it, whichever way the agent asked. The acpmux MCP
// `who_else` tool (Claude's `mcp__acpmux__who_else`, Codex's `{server, tool, arguments}`, or folded
// into cmux_exec as `acpmux_who_else`) returns it as structured content; `acpmux who-else --json`
// in a shell prints it. Either becomes one card (`WhoElseCard`), never raw JSON in the transcript.
import type { AcpmuxActivity } from "../model";
import { safeHref } from "../replyHref";
import { mcpCall } from "./mcpCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export const WHO_ELSE_SCHEMA = "acpmux.who-else.v1";

export type WhoElseFile = { path: string; edited: boolean; at?: number };

export type WhoElseSession = {
  sessionId: string;
  name: string;
  /// The name to open or message it by: `HOST/NAME` for a peer's session, else its name.
  ref: string;
  title?: string;
  harness: string;
  host?: string;
  status: string;
  live: boolean;
  branch?: string;
  pullRequests: string[];
  agoMs: number;
  filesInCommon: number;
  editedInCommon: number;
  files: WhoElseFile[];
  sameWorktree: boolean;
  sameBranch: boolean;
  topicWords: string[];
};

export type WhoElseAnswer = {
  sessions: WhoElseSession[];
  more: number;
  /// Peers that did not answer in time.
  unreached: string[];
  /// The files the question named (up to 20) and how many in all.
  files: string[];
  fileCount: number;
  topic?: string;
};

export type WhoElseCall = {
  /// Still running: no answer yet.
  pending: boolean;
  answer?: WhoElseAnswer;
};

const TOOL_NAME = /^(?:acpmux[_.]|acpmux__)?who_?else$/i;
const CLI =
  /(?:^|(?:&&|\|\||;)\s*)(?:\w+=\S+\s+)*(?:\S+\/)?acpmux(?:-debug-cli)?\s+(?:--json\s+)?(?:who-?else|overlap)(?:\s|$)/i;

/// The who-else question a tool call asks, with its answer once there, or undefined for any other
/// call. A shell call counts only when it asked for `--json` (a text answer stays shell output).
export function whoElseCall(item: AcpmuxActivity): WhoElseCall | undefined {
  const tool = item.tool;
  if (!tool) return undefined;
  if (!asksWhoElse(tool)) return undefined;
  const pending = tool.status === "pending" || tool.status === "in_progress";
  const answer = findAnswer(parseJSON(tool.output), 0);
  if (!answer && !pending) return undefined;
  return { pending: pending && !answer, answer };
}

function asksWhoElse(tool: Tool): boolean {
  const mcp = mcpCall(tool);
  // Another server's tool of the same name is that server's: its output draws as itself.
  if (mcp) {
    const server = mcp.server.toLowerCase();
    return (server === "acpmux" || server === "cmux") && TOOL_NAME.test(mcp.tool);
  }
  if (TOOL_NAME.test(tool.title.trim())) return true;
  return Boolean(tool.command && CLI.test(tool.command) && /--json\b/.test(tool.command));
}

/// The answer anywhere in `value`: the object itself, an MCP result's structured content or text
/// block, or a cmux_exec envelope around one. At most a few levels down.
function findAnswer(value: unknown, depth: number): WhoElseAnswer | undefined {
  if (depth > 4 || value === undefined || value === null) return undefined;
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed.startsWith("{") || trimmed.startsWith("[") ? findAnswer(parseJSON(trimmed), depth + 1) : undefined;
  }
  if (Array.isArray(value)) {
    for (const entry of value) {
      const found = findAnswer(entry, depth + 1);
      if (found) return found;
    }
    return undefined;
  }
  if (!isRecord(value)) return undefined;
  if (value.schema === WHO_ELSE_SCHEMA && Array.isArray(value.sessions)) return answerOf(value);
  for (const key of ["structuredContent", "result", "value", "content", "text", "output"]) {
    const found = findAnswer(value[key], depth + 1);
    if (found) return found;
  }
  return undefined;
}

function answerOf(raw: Record<string, unknown>): WhoElseAnswer {
  const query = isRecord(raw.query) ? raw.query : {};
  return {
    sessions: (raw.sessions as unknown[]).filter(isRecord).map(sessionOf),
    more: num(raw.more),
    unreached: (Array.isArray(raw.unreached) ? raw.unreached : [])
      .map((u) => (isRecord(u) && typeof u.host === "string" ? u.host : undefined))
      .filter((h): h is string => Boolean(h)),
    files: strings(query.files),
    fileCount: num(query.fileCount),
    topic: str(query.topic),
  };
}

function sessionOf(raw: Record<string, unknown>): WhoElseSession {
  const name = str(raw.name) ?? str(raw.sessionId) ?? "";
  return {
    sessionId: str(raw.sessionId) ?? "",
    name,
    ref: str(raw.ref) ?? name,
    title: str(raw.title),
    harness: str(raw.harness) ?? "",
    host: str(raw.host),
    status: str(raw.status) ?? "",
    live: raw.live === true,
    branch: str(raw.branch),
    // Tool output is untrusted: a link is drawn only to an https URL (`safeHref`), never `javascript:`.
    pullRequests: strings(raw.pullRequests).flatMap((u) => {
      const href = safeHref(u);
      return href?.startsWith("https://") ? [href] : [];
    }),
    agoMs: num(raw.agoMs),
    filesInCommon: num(raw.filesInCommon),
    editedInCommon: num(raw.editedInCommon),
    files: (Array.isArray(raw.files) ? raw.files : []).filter(isRecord).flatMap((f) => {
      const path = str(f.path);
      return path ? [{ path, edited: f.edited === true, at: typeof f.at === "number" ? f.at : undefined }] : [];
    }),
    sameWorktree: raw.sameWorktree === true,
    sameBranch: raw.sameBranch === true,
    topicWords: strings(raw.topicWords),
  };
}

/// `#123` for a pull request URL, else the URL's last part.
export function pullLabel(url: string): string {
  const number = /\/pull\/(\d+)/.exec(url)?.[1];
  return number ? `#${number}` : (url.split("/").pop() ?? url);
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function num(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
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
