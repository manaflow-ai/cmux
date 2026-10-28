// MCP tool calls as the transcript says them: one line naming what the call did to what ("Sent 4
// messages to Coordination hub", "Read Coordination hub"), never the harness's machine name
// (`mcp__codex_apps__send_message`, `codex_apps.send_message call`); and, once opened, the call's
// request and response pretty-printed with nested JSON strings parsed and the host's injected
// context blocks (`<in-app-browser-context>`) dropped.
import { createContext } from "react";
import type { Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";
import {
  envelopeImages,
  formatToolText,
  losesNumbers,
  oneLine,
  peelEnvelope,
  printable,
  toolResult,
} from "./toolResult";
import { stripAnsi } from "./toolOutput";

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
export type McpAction = "message" | "read" | "list" | "search" | "create" | "start" | "update" | "delete" | "call";

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
  start: "start",
  launch: "start",
  spawn: "start",
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

/// Whether a parsed MCP call is explicitly observational, regardless of its generic ACP kind. The first verb supplies the parsed
/// action; a later mutating word makes names such as `read_and_write` fail closed rather than
/// becoming read-only because they happen to start with `read`.
const MCP_MUTATING_WORDS = new Set([
  "write",
  "append",
  "truncate",
  "overwrite",
  "mutate",
  "modify",
  "execute",
  "run",
  "send",
  "post",
  "reply",
  "create",
  "add",
  "new",
  "start",
  "launch",
  "spawn",
  "update",
  "edit",
  "set",
  "rename",
  "patch",
  "delete",
  "remove",
  "archive",
  "close",
  "replace",
  "upload",
  "copy",
  "save",
  "put",
]);

export function mcpIsObservational(call: McpCall): boolean {
  const tokens = words(call.tool);
  const action = mcpAction(call);
  return (
    (action === "read" || action === "list" || action === "search") &&
    !tokens.slice(1).some((token) => MCP_MUTATING_WORDS.has(token) || VERBS[token] === "message") &&
    !tokens.slice(1).some((token) => VERBS[token] !== undefined && !["read", "list", "search"].includes(VERBS[token]!))
  );
}

/// Arguments that name what a call acts on, in the order they are tried.
const NAME_KEYS = ["title", "name", "subject", "path", "file_path", "filePath", "url", "query", "q", "to", "recipient"];
/// A message is named by whom it went to, never by its subject or body.
const MESSAGE_KEYS = ["to", "recipient", "title", "name"];
/// Arguments holding an id the run's other calls may name (`id`, `chat_id`, `threadId`), not words
/// that merely end in "id" (`valid`, `paid`).
const ID_KEY = /^(?:id|[a-zA-Z]+_id|[a-z]+Id)$/;

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
  for (const key of mcpAction(call) === "message" ? MESSAGE_KEYS : NAME_KEYS) {
    const value = args[key];
    if (typeof value === "string" && value.trim() && value.length <= 200) return value.trim();
  }
  for (const [key, value] of Object.entries(args))
    if (ID_KEY.test(key) && typeof value === "string" && names.has(value)) return names.get(value);
  return undefined;
}

/// The name a call has before it is humanized: Claude Code's `mcp__<server>__<tool>`, or Codex's
/// `<server>.<tool>`. Rows keep it in their opened details.
export function mcpRawName(tool: Tool, call: McpCall): string {
  const title = tool.title.trim();
  return CLAUDE_NAME.test(title) ? title : `${call.server}.${call.tool}`;
}

/// An MCP server's name in plain words: `codex_apps` reads "codex apps".
function serverWords(server: string): string {
  return server.replace(/_+/g, " ").trim() || server;
}

/// A call in plain words where no translation is at hand (the running line, a permission's
/// subject): the server, then the tool's words and what it acts on, as in
/// "cmux-subsessions · start session sidebar-drag-bugs" or "cmux · list workspaces".
export function mcpPlainName(call: McpCall, names: McpNames = new Map()): string {
  const target = mcpTarget(call, names);
  const action = words(call.tool).join(" ") || call.tool;
  return `${serverWords(call.server)} · ${action}${target ? ` ${target}` : ""}`;
}

/// The plain name of a title that is an MCP tool id (`mcp__<server>__<tool>`), from the title
/// alone, or nil for any other title.
export function mcpTitleName(title: string): string | undefined {
  const name = CLAUDE_NAME.exec(title.trim());
  return name ? mcpPlainName({ server: name[1]!, tool: name[2]!, args: undefined }) : undefined;
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
  // A start names what it started and its name: "Started session sidebar-drag-bugs".
  const noun = toolNoun(first);
  const object = target ? (action === "start" && noun !== first.tool ? `${noun} ${target}` : target) : noun;
  const line =
    action === "call"
      ? t("tools.mcp.call", { target: `${serverWords(first.server)} · ${noun}` })
      : t(`tools.mcp.${action}`, { target: object });
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
/// One closed block (text that merely names a tag keeps everything after it), never reaching into
/// another of its tag: anchored at the end, a lazy match would otherwise start at a block in the
/// middle and swallow the text up to the last one.
const BLOCK = `<(${INTERNAL_TAGS.join("|")})\\b[^>]*>(?:(?!<\\1\\b)[\\s\\S])*?</\\1>`;
const LEADING_BLOCK = new RegExp(`^\\s*${BLOCK}\\s*`);
const TRAILING_BLOCK = new RegExp(`\\s*${BLOCK}\\s*$`);

/// `text` without the internal context blocks a host injected at its start or end. A block in the
/// middle is the text's own (a template or a file that quotes one) and stays.
export function cleanText(text: string): string {
  if (!text.includes("<")) return text;
  let out = text;
  for (let found = true; found;) {
    const next = out.replace(LEADING_BLOCK, "");
    found = next !== out;
    out = next;
  }
  for (let found = true; found;) {
    const end = TRAILING_BLOCK.exec(out);
    found = Boolean(end);
    if (end) out = `${out.slice(0, end.index)}${/\n\s*$/.test(end[0]) ? "\n" : ""}`;
  }
  return out;
}

/// A JSON value with every string cleaned, and every string that holds JSON parsed in its place.
function deepClean(value: unknown, depth = 0): unknown {
  if (typeof value === "string") {
    // Parsed before it is cleaned: inside JSON text a block's line breaks are still escaped.
    // JSON holding a number a double would change stays the text it is, never parsed and rounded.
    if (depth < 8 && /^\s*[[{]/.test(value) && !losesNumbers(value)) {
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

/// An MCP response as a value: an envelope that says only text unwrapped to its texts.
function mcpValue(output: string | undefined): unknown {
  if (!output) return undefined;
  const parsed = parseJSON(output);
  if (parsed === undefined) return output;
  const peeled = oneLine(output) ? peelEnvelope(parsed) : undefined;
  if (!peeled || peeled.rest.length) return parsed;
  const texts = peeled.texts.filter((text) => text.trim());
  if (!texts.length) return parsed;
  return texts.length === 1 ? texts[0] : texts;
}

/// Whether the output is an envelope that holds more than text (structured content, an error's
/// data, a block that is not text), at its top or in an envelope its text holds, as toolResult.ts
/// reads text that is JSON again.
function holdsMore(output: string, depth = 0): boolean {
  if (depth > 6 || !oneLine(output)) return false;
  const parsed = parseJSON(output);
  const peeled = parsed === undefined ? undefined : peelEnvelope(parsed);
  if (!peeled) return false;
  if (peeled.rest.length) return true;
  return holdsMore(cleanText(peeled.texts.join("\n\n")).replace(/\n$/, ""), depth + 1);
}

/// A value as the opened call shows it: text as itself, anything else as indented JSON.
export function prettyValue(value: unknown): string | undefined {
  // Nested too deep to indent (each level would indent every line below it): on one line, as it came.
  const raw = typeof value === "string" ? parseJSON(value) : value;
  if (raw !== undefined && !printable(raw)) return typeof value === "string" ? value.replace(/\n$/, "") : flat(value);
  const clean = deepClean(value);
  if (clean === undefined || clean === null || clean === "") return undefined;
  if (typeof clean === "string") return clean.replace(/\n$/, "");
  if (isRecord(clean) && Object.keys(clean).length === 0) return undefined;
  return JSON.stringify(clean, null, 2);
}

/// The opened call's response. `strip`: whether the call's strip shows its envelope's images
/// (toolImages.ts `stripsEnvelopeImages`).
export function prettyOutput(output: string | undefined, strip = false): string | undefined {
  // JSON holding a number a double would change (a 64-bit ID) shows as it came, never parsed and
  // rounded, as toolResult.ts shows it.
  if (output && parseJSON(output) !== undefined && losesNumbers(output)) return output.replace(/\n$/, "");
  // An envelope whose images the strip shows reads as the tool row reads it: its text, without them.
  if (output && strip && envelopeImages(output).length) return toolResult(output, cleanText, true).text || undefined;
  // An envelope that holds more than text reads exactly as the tool row reads it: its text, then
  // each other part as the JSON it is, never cleaned or parsed again (toolResult.ts).
  if (output && holdsMore(output)) return toolResult(output, cleanText).text || undefined;
  return prettyValue(mcpValue(output));
}

/// The response as both its readable body and Find see it. Keep the MCP reader's recursive
/// context cleaning, then remove terminal controls and classify without peeling its text again.
export function mcpOutputResult(output: string | undefined, strip: boolean, name: string) {
  const text = prettyOutput(output, strip);
  return text ? formatToolText(stripAnsi(text), { title: name }) : undefined;
}

function flat(value: unknown): string | undefined {
  try {
    return JSON.stringify(value);
  } catch {
    return undefined;
  }
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
