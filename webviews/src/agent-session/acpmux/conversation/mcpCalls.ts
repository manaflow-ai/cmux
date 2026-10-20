// MCP tool calls as the transcript says them: one line naming what the call did to what ("Sent 4
// messages to Coordination hub", "Read Coordination hub"), never the harness's machine name
// (`mcp__codex_apps__send_message`, `codex_apps.send_message call`); and, once opened, the call's
// request and response pretty-printed with nested JSON strings parsed and the host's injected
// context blocks (`<in-app-browser-context>`) dropped.
import { createContext } from "react";
import type { Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type McpCall = {
  server: string;
  tool: string;
  /// The tool's arguments, as the harness passed them.
  args: unknown;
};

/// Claude Code's MCP tool name: `mcp__<server>__<tool>`.
const CLAUDE_NAME = /^mcp__(.+?)__(.+)$/;

/// The MCP server and tool a call ran, or nil for any other call. Claude Code names the call
/// `mcp__<server>__<tool>` with the arguments as its input; Codex nests them under
/// `{server, tool, arguments}`.
export function mcpCall(tool: Tool): McpCall | undefined {
  const name = CLAUDE_NAME.exec(tool.title.trim());
  if (name) return { server: name[1]!, tool: name[2]!, args: parseJSON(tool.inputSummary) };
  const input = parseJSON(tool.inputSummary);
  if (
    isRecord(input) &&
    typeof input.server === "string" &&
    typeof input.tool === "string" &&
    "arguments" in input &&
    !tool.command
  )
    return { server: input.server, tool: input.tool, args: input.arguments };
  return undefined;
}

/// Calls of one server's tool group with their neighbors.
export function mcpKey(call: McpCall): string {
  return `${call.server}\u0000${call.tool}`;
}

/// What a call does, from its tool's first word.
export type McpAction = "message" | "read" | "list" | "search" | "create" | "update" | "delete" | "call";

const VERBS: Record<string, McpAction> = {
  send: "message",
  post: "message",
  reply: "message",
  message: "message",
  read: "read",
  get: "read",
  fetch: "read",
  view: "read",
  open: "read",
  show: "read",
  load: "read",
  list: "list",
  search: "search",
  find: "search",
  query: "search",
  lookup: "search",
  create: "create",
  add: "create",
  new: "create",
  start: "create",
  update: "update",
  edit: "update",
  set: "update",
  rename: "update",
  patch: "update",
  delete: "delete",
  remove: "delete",
  archive: "delete",
  close: "delete",
};

function words(tool: string): string[] {
  return tool
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .split(/[\s_.\-/:]+/)
    .filter(Boolean)
    .map((word) => word.toLowerCase());
}

export function mcpAction(call: McpCall): McpAction {
  return VERBS[words(call.tool)[0] ?? ""] ?? "call";
}

/// Arguments that name what a call acts on, in the order they are tried.
const NAME_KEYS = ["title", "name", "subject", "path", "file_path", "filePath", "url", "query", "q", "to", "recipient"];
/// Arguments holding an id the run's other calls may name (`threadId`, `chat_id`, `id`).
const ID_KEY = /^(?:[a-z]*_?)?id$/i;

/// Ids to titles, from objects in the run's MCP requests and responses that carry both
/// (`{"id": "01a1…", "title": "Coordination hub"}`), so a call that names only an id reads by title.
export type McpNames = ReadonlyMap<string, string>;
export const McpNamesContext = createContext<McpNames>(new Map());

const namesCache = new WeakMap<Tool, [string, string][]>();
/// Responses larger than this are not searched for names: a label must stay cheap to draw.
const NAMES_MAX_CHARS = 256_000;

export function mcpNames(items: readonly AcpmuxActivity[] | undefined): McpNames {
  const names = new Map<string, string>();
  for (const item of items ?? []) {
    const tool = item.tool;
    if (!tool) continue;
    let found = namesCache.get(tool);
    if (!found) {
      found = [];
      if (mcpCall(tool)) {
        const pairs = found;
        const collect = (value: unknown, depth: number) => {
          if (depth > 6 || pairs.length > 200) return;
          if (Array.isArray(value)) for (const entry of value) collect(entry, depth + 1);
          else if (isRecord(value)) {
            const id = value.id ?? value.threadId ?? value.thread_id;
            const title = value.title ?? value.name;
            if (typeof id === "string" && typeof title === "string" && title.trim())
              pairs.push([id, cleanText(title).trim()]);
            for (const entry of Object.values(value)) collect(entry, depth + 1);
          }
        };
        if ((tool.output?.length ?? 0) <= NAMES_MAX_CHARS) collect(deepClean(mcpValue(tool.output)), 0);
        collect(mcpCall(tool)!.args, 0);
      }
      namesCache.set(tool, found);
    }
    for (const [id, title] of found) if (!names.has(id)) names.set(id, title);
  }
  return names;
}

/// What a call acts on: a name among its arguments, or an id the run's names resolve.
export function mcpTarget(call: McpCall, names: McpNames): string | undefined {
  const args = call.args;
  if (!isRecord(args)) return undefined;
  for (const key of NAME_KEYS) {
    const value = args[key];
    if (typeof value === "string" && value.trim() && value.length <= 200) return value.trim();
  }
  for (const [key, value] of Object.entries(args))
    if (ID_KEY.test(key) && typeof value === "string" && names.has(value)) return names.get(value);
  return undefined;
}

/// The rest of the tool's name after its verb, for a call with no target: `read_chat` reads "chat".
function toolNoun(call: McpCall): string {
  const all = words(call.tool);
  const rest = mcpAction(call) === "call" ? all : all.slice(1);
  return rest.join(" ") || call.tool;
}

/// One line for a run of calls to one MCP tool.
export function mcpLabel(t: Translate, calls: readonly McpCall[], names: McpNames): string {
  const first = calls[0]!;
  const targets = new Set(calls.map((call) => mcpTarget(call, names)));
  const target = targets.size === 1 ? [...targets][0] : undefined;
  const n = calls.length;
  const action = mcpAction(first);
  if (action === "message") {
    if (target) return n === 1 ? t("tools.mcp.message.one", { target }) : t("tools.mcp.message.other", { n, target });
    return n === 1 ? t("tools.mcp.message.oneBare") : t("tools.mcp.message.otherBare", { n });
  }
  const object = target ?? toolNoun(first);
  const line =
    action === "call" ? t("tools.mcp.call", { target: first.tool }) : t(`tools.mcp.${action}`, { target: object });
  return n > 1 ? `${line} ×${n}` : line;
}

/// Tags of context a host injects into what an agent sees, never meant for the reader.
const INTERNAL_TAGS = [
  "in-app-browser-context",
  "system-reminder",
  "environment_context",
  "ide_selection",
  "ide_opened_file",
];
const INTERNAL_BLOCK = new RegExp(`<(${INTERNAL_TAGS.join("|")})\\b[^>]*>[\\s\\S]*?(?:</\\1>|$)\\s*`, "g");

/// `text` without the internal context blocks a host injected into it.
export function cleanText(text: string): string {
  return text.includes("<") ? text.replace(INTERNAL_BLOCK, "") : text;
}

/// A JSON value with every string cleaned, and every string that holds JSON parsed in its place.
function deepClean(value: unknown, depth = 0): unknown {
  if (typeof value === "string") {
    // Parsed before it is cleaned: inside JSON text a block's line breaks are still escaped.
    if (depth < 8 && /^\s*[[{]/.test(value)) {
      const parsed = parseJSON(value);
      if (parsed !== undefined) return deepClean(parsed, depth + 1);
    }
    return cleanText(value);
  }
  if (Array.isArray(value)) return value.map((entry) => deepClean(entry, depth + 1));
  if (isRecord(value)) {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value)) out[key] = deepClean(entry, depth + 1);
    return out;
  }
  return value;
}

/// An MCP response as a value: a `{content: [{type: "text", text}]}` result unwrapped to its texts.
function mcpValue(output: string | undefined): unknown {
  if (!output) return undefined;
  const parsed = parseJSON(output);
  if (parsed === undefined) return output;
  const content =
    isRecord(parsed) && Array.isArray(parsed.content) ? parsed.content : Array.isArray(parsed) ? parsed : undefined;
  if (content && content.length && content.every((block) => isRecord(block) && block.type === "text")) {
    const texts = content.map((block) => String((block as { text?: unknown }).text ?? ""));
    return texts.length === 1 ? texts[0] : texts;
  }
  return parsed;
}

/// A value as the opened call shows it: text as itself, anything else as indented JSON.
export function prettyValue(value: unknown): string | undefined {
  const clean = deepClean(value);
  if (clean === undefined || clean === null || clean === "") return undefined;
  if (typeof clean === "string") return clean.replace(/\n$/, "");
  if (isRecord(clean) && Object.keys(clean).length === 0) return undefined;
  return JSON.stringify(clean, null, 2);
}

/// The opened call's response.
export function prettyOutput(output: string | undefined): string | undefined {
  return prettyValue(mcpValue(output));
}

function parseJSON(text: string | undefined): unknown {
  if (!text) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
