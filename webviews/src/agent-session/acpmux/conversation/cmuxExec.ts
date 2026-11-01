// The cmux MCP server's own calls as the transcript says them (Leo, 2026-10-30: "these should be
// rendered better than just cmux called cmux exec we know what these are supposed to be"): a
// `cmux_exec` script reads as what it did, from its result's `call_log` once it has finished
// ("Opened 12 agent sessions in Leads") and from the `cmux.call("<name>")` / `cmux.<tool>(` calls in
// its script while it runs ("Listing workspaces"); a `cmux_docs` search and the server's own tools
// called directly (`mcp__cmux__workspace_list`) read the same way. Every other MCP tool keeps
// mcpCalls.ts's line.
//
// What a call holds is read once per tool-call snapshot (`execView`, a WeakMap on the immutable
// tool object), never per render or per streamed token; a title is that summary put into words.
import type { StringKey, Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";
import type { McpCall, McpNames } from "./mcpCalls";
import { losesNumbers } from "./toolResult";
import { treeText, valueTree, type TreeLine } from "./valueTree";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The code-mode tools the cmux server lists (cmux-tui `cli/mcp/code_mode.rs` EXEC and DOCS).
const EXEC = "cmux_exec";
const DOCS = "cmux_docs";

/// The cmux server's MCP name: Claude Code's `mcp__cmux__…`, Codex's `cmux.…`, and any harness
/// that names it `cmux-next` or `cmux_app`.
const CMUX_SERVER = /^cmux(?:[-_](?:next|app|dev))?$/i;

/// Tool families that are the cmux server's own (its daemon and app tools). Other families the
/// server folds in (`cua_*`, `subsessions_*`, `secrets_*`, `forum_*`, `acpmux_*`) belong to other
/// servers and keep their own rows.
const OWN_FAMILIES = new Set(["workspace", "pane", "tab", "terminal", "screen", "window", "notification", "app"]);

/// One entry of the verb table: the line once the calls finished (a plural string over `{n}` when
/// it counts) and while they run, whether it changes something (a change outranks a lookup in a
/// script's title) and whether it names the workspace it acted in.
type Verb = { done: StringKey; doing: StringKey; change: boolean; counts?: boolean; where?: boolean };

const verb = (done: StringKey, doing: StringKey, change: boolean, extra: Partial<Verb> = {}): Verb => ({
  done,
  doing,
  change,
  ...extra,
});

/// cmux tool names to what they did. Calls that read the same way share one entry, so a script
/// that opens sessions with both `app_agent_open` and `app_agent_open_tab` counts them together.
const OPENED_AGENTS = verb("tools.cmux.openedAgentSessions", "tools.cmux.openingAgentSession", true, {
  counts: true,
  where: true,
});
const OPENED_BROWSER = verb("tools.cmux.openedBrowserTabs", "tools.cmux.openingBrowserTab", true, {
  counts: true,
  where: true,
});
const RENAMED_WORKSPACES = verb("tools.cmux.renamedWorkspaces", "tools.cmux.renamingWorkspace", true, { counts: true });
const READ_TERMINAL = verb("tools.cmux.readTerminal", "tools.cmux.readingTerminal", false);
const VERBS: Record<string, Verb> = {
  workspace_list: verb("tools.cmux.listedWorkspaces", "tools.cmux.listingWorkspaces", false),
  pane_list: verb("tools.cmux.listedPanes", "tools.cmux.listingPanes", false),
  tab_list: verb("tools.cmux.listedTabs", "tools.cmux.listingTabs", false),
  terminal_list: verb("tools.cmux.listedTerminals", "tools.cmux.listingTerminals", false),
  workspace_create: verb("tools.cmux.createdWorkspaces", "tools.cmux.creatingWorkspace", true, { counts: true }),
  workspace_rename: RENAMED_WORKSPACES,
  app_workspace_rename: RENAMED_WORKSPACES,
  tab_rename: verb("tools.cmux.renamedTabs", "tools.cmux.renamingTab", true, { counts: true }),
  tab_create_terminal: verb("tools.cmux.openedTerminals", "tools.cmux.openingTerminal", true, {
    counts: true,
    where: true,
  }),
  tab_create_browser: OPENED_BROWSER,
  workspace_open_url: OPENED_BROWSER,
  app_agent_open: OPENED_AGENTS,
  app_agent_open_tab: OPENED_AGENTS,
  terminal_input_write: verb("tools.cmux.typedInTerminal", "tools.cmux.typingInTerminal", true, { counts: true }),
  terminal_wait: verb("tools.cmux.waitedForTerminal", "tools.cmux.waitingForTerminal", false),
  terminal_screen_read: READ_TERMINAL,
  terminal_history_read: READ_TERMINAL,
  pane_split: verb("tools.cmux.splitPanes", "tools.cmux.splittingPane", true, { counts: true, where: true }),
  tab_close: verb("tools.cmux.closedTabs", "tools.cmux.closingTab", true, { counts: true }),
  tab_focus: verb("tools.cmux.focusedTab", "tools.cmux.focusingTab", true),
  workspace_status_set: verb("tools.cmux.setStatus", "tools.cmux.settingStatus", true),
  notification_create: verb("tools.cmux.sentNotifications", "tools.cmux.sendingNotification", true, { counts: true }),
};

/// Generic cmux names (`<noun>_<verb>`, as `workspace_get` or `tab_update`) the table leaves out,
/// in the MCP rows' words (mcpCalls.ts `tools.mcp.*`). Only verbs whose meaning is plain; any other
/// name reads in the script's fallback line, by its name.
const GENERIC: Record<string, "read" | "list" | "search" | "create" | "update" | "delete"> = {
  get: "read",
  read: "read",
  show: "read",
  view: "read",
  list: "list",
  search: "search",
  find: "search",
  create: "create",
  add: "create",
  update: "update",
  set: "update",
  rename: "update",
  edit: "update",
  delete: "delete",
  remove: "delete",
};

/// A tool name's words: `tab_create_terminal` is "tab create terminal".
const nameWords = (name: string) => name.split(/[_.\-\s]+/).filter(Boolean);
const spoken = (name: string) => nameWords(name).join(" ") || name;

/// Whether `call` is the cmux server's own: `cmux_exec`, `cmux_docs`, or one of its tools the
/// transcript knows how to say.
export function isCmuxCall(call: McpCall): boolean {
  if (!CMUX_SERVER.test(call.server)) return false;
  if (call.tool === EXEC || call.tool === DOCS) return true;
  return OWN_FAMILIES.has(nameWords(call.tool)[0] ?? "") && (call.tool in VERBS || genericOf(call.tool) !== undefined);
}

/// Whether `call` runs a cmux script, which draws its own row even beside another script.
export function isCmuxExec(call: McpCall): boolean {
  return CMUX_SERVER.test(call.server) && call.tool === EXEC;
}

function genericOf(name: string): { action: (typeof GENERIC)[string]; noun: string } | undefined {
  const words = nameWords(name);
  for (let at = words.length - 1; at > 0; at--) {
    const action = GENERIC[words[at]!];
    if (action) return { action, noun: [...words.slice(0, at), ...words.slice(at + 1)].join(" ") };
  }
  return undefined;
}

/// One record of a script's `call_log` (code_mode.rs `exec`): the tool it called and how it went.
export type ExecCall = { name: string; ok: boolean; state?: string };

/// What a `cmux_exec` call holds, read once per snapshot of the call.
export type ExecView = {
  /// The script, with its real line breaks.
  script?: string;
  /// The tools its source calls, in order, each once (`cmux.call("x")`, `cmux.x(`).
  scriptCalls: string[];
  /// Whether its source searches the tools (`cmux.docs(`), and the one query it searches for.
  docs: boolean;
  docsQuery?: string;
  /// The finished script's answer (`{calls, call_log, logs, result}` or `{error, state, …}`), when
  /// its response is one.
  answer?: {
    calls: number;
    callLog: ExecCall[];
    truncated: boolean;
    result?: unknown;
    error?: unknown;
    logs: string[];
    hasResult: boolean;
    /// False when the response holds a number a double would change (a 64-bit id): the opened row
    /// then shows the response as it came, never parsed and rounded (toolResult.ts).
    exact: boolean;
  };
  /// The workspace the script acted in, by name, when it names exactly one.
  workspace?: string;
};

const viewCache = new WeakMap<Tool, ExecView>();
/// Responses larger than this are not searched for their answer (the server caps a result well
/// below it, code_mode.rs `fit`).
const MAX_ANSWER_CHARS = 1_000_000;

/// The call's script and answer. `args` is the call's arguments (mcpCalls.ts `mcpCall`).
export function execView(tool: Tool, args: unknown): ExecView {
  const cached = viewCache.get(tool);
  if (cached) return cached;
  const script = isRecord(args) && typeof args.script === "string" ? args.script : undefined;
  const source = script ?? "";
  const answer = !isRunningTool(tool) && tool.output ? readAnswer(tool.output) : undefined;
  const docsQueries = [...source.matchAll(/cmux\.docs\(\s*(["'`])((?:(?!\1)[^\\\n]|\\.){1,80})\1/g)].map((m) => m[2]!);
  const view: ExecView = {
    ...(script !== undefined && { script }),
    scriptCalls: scriptCalls(source),
    docs: /\bcmux\.docs\s*\(/.test(source),
    ...(new Set(docsQueries).size === 1 && { docsQuery: docsQueries[0] }),
    ...(answer && { answer }),
  };
  const workspace = workspaceName(source, answer?.result);
  if (workspace) view.workspace = workspace;
  viewCache.set(tool, view);
  return view;
}

const isRunningTool = (tool: Tool) => tool.status === "pending" || tool.status === "in_progress";

/// The tools a script's source calls, in order, each once: `cmux.call("name", …)` and
/// `cmux.<name>(…)`, `cmux.docs` aside (it is a search, not a call).
export function scriptCalls(source: string): string[] {
  const names: string[] = [];
  const seen = new Set<string>();
  const pattern = /\bcmux\s*\.\s*(?:call\s*\(\s*(["'`])([A-Za-z][\w.]{0,127})\1|([A-Za-z_]\w{0,127})\s*\()/g;
  for (const match of source.slice(0, 256 << 10).matchAll(pattern)) {
    const name = match[2] ?? match[3]!;
    if (name === "call" || name === "docs" || seen.has(name)) continue;
    seen.add(name);
    names.push(name);
    if (names.length >= 64) break;
  }
  return names;
}

/// The script's answer in its response: the object with its `call_log`, wherever the harness put
/// it (the MCP result's structured content, its text block, or the text itself), or nil for a
/// response that holds none (an error the harness wrote as text, a cut response).
export function readAnswer(output: string): ExecView["answer"] {
  if (output.length > MAX_ANSWER_CHARS) return undefined;
  // Every JSON layer is checked before it is parsed (the response, then any text block in it):
  // one with an integer a double would round keeps the answer from drawing as a tree.
  const layers = { exact: !losesNumbers(output) };
  const found = findAnswer(parse(output), 0, layers);
  if (!found) return undefined;
  const records = Array.isArray(found.call_log) ? found.call_log : [];
  const callLog: ExecCall[] = [];
  for (const record of records) {
    if (!isRecord(record) || typeof record.name !== "string") continue;
    callLog.push({
      name: record.name,
      ok: record.ok === true,
      ...(typeof record.state === "string" && { state: record.state }),
    });
  }
  const logs = Array.isArray(found.logs) ? found.logs.filter((line): line is string => typeof line === "string") : [];
  return {
    calls: typeof found.calls === "number" && Number.isFinite(found.calls) ? found.calls : callLog.length,
    callLog,
    truncated: found.call_log_truncated === true,
    ...("result" in found && { result: found.result }),
    ...("error" in found && { error: found.error }),
    logs,
    hasResult: "result" in found,
    exact: layers.exact,
  };
}

function findAnswer(value: unknown, depth: number, layers: { exact: boolean }): Record<string, unknown> | undefined {
  if (depth > 5) return undefined;
  if (typeof value === "string") {
    if (!/^\s*\{/.test(value)) return undefined;
    const parsed = parse(value);
    const found = findAnswer(parsed, depth + 1, layers);
    if (found && losesNumbers(value)) layers.exact = false;
    return found;
  }
  if (Array.isArray(value)) {
    for (const entry of value.slice(0, 8)) {
      const found = findAnswer(entry, depth + 1, layers);
      if (found) return found;
    }
    return undefined;
  }
  if (!isRecord(value)) return undefined;
  if (Array.isArray(value.call_log) || (typeof value.calls === "number" && ("result" in value || "error" in value)))
    return value;
  // The MCP result: its structured content first (the answer itself), then its blocks' text.
  for (const key of ["structuredContent", "content", "text", "output", "result"]) {
    if (!(key in value)) continue;
    const found = findAnswer(value[key], depth + 1, layers);
    if (found) return found;
  }
  return undefined;
}

/// A selector the server resolves (`current`, `focused`) or a public id, never a name to show.
const NOT_A_NAME = /^(?:current|focused|ws_[\w-]+|[0-9a-f]{8}-[0-9a-f-]{27,}|[0-9A-HJKMNP-TV-Z]{26})$/i;

/// The one workspace a script names: a `workspace: "Leads"` argument, the title it looks a
/// workspace up by (`w.title === "Leads"`), or a workspace its result names. Nil when it names
/// none or more than one.
function workspaceName(source: string, result: unknown): string | undefined {
  const names = new Set<string>();
  const add = (value: unknown) => {
    if (typeof value !== "string") return;
    const name = value.trim();
    if (name && name.length <= 80 && !NOT_A_NAME.test(name) && !name.includes("${")) names.add(name);
  };
  for (const match of source.matchAll(/\bworkspace\s*:\s*(["'`])([^"'`\n\\]{1,80})\1/g)) add(match[2]);
  if (/\bworkspace_list\b/.test(source))
    for (const match of source.matchAll(/\.(?:title|name)\s*===?\s*(["'`])([^"'`\n\\]{1,80})\1/g)) add(match[2]);
  if (!names.size && isRecord(result)) {
    for (const key of ["workspace", "workspace_title", "workspaceTitle", "workspace_name", "workspaceName"]) {
      const value = result[key];
      add(isRecord(value) ? (value.title ?? value.name) : value);
    }
  }
  return names.size === 1 ? [...names][0] : undefined;
}

/// The plain words of an id the run's other calls name (mcpCalls.ts `mcpNames`).
function argWorkspace(args: unknown, names: McpNames): string | undefined {
  if (!isRecord(args)) return undefined;
  const value = args.workspace ?? args.workspace_id;
  if (typeof value !== "string") return undefined;
  if (names.has(value)) return names.get(value);
  return NOT_A_NAME.test(value.trim()) ? undefined : value.trim();
}

/// One step of a title: the verb entry (or a generic name), how many times it ran.
type Step = { name: string; count: number; verb?: Verb };

/// The calls of a finished script, by verb entry, in the order they first ran; a call that failed
/// counts only when none of its kind went through.
function finishedSteps(callLog: readonly ExecCall[]): Step[] {
  const steps = new Map<Verb | string, Step & { ok: number }>();
  for (const call of callLog) {
    const entry = VERBS[call.name];
    const key = entry ?? call.name;
    let step = steps.get(key);
    if (!step) {
      step = { name: call.name, count: 0, ok: 0, ...(entry && { verb: entry }) };
      steps.set(key, step);
    }
    step.count += 1;
    if (call.ok) step.ok += 1;
  }
  return [...steps.values()].map(({ ok, ...step }) => ({ ...step, count: ok || step.count }));
}

/// A change outranks a lookup; among changes the one done most times; then the first.
function mainStep(steps: readonly Step[]): { main: Step; others: number } | undefined {
  const known = steps.filter((step) => step.verb || genericOf(step.name));
  if (!known.length) return undefined;
  const changes = known.filter((step) => step.verb?.change ?? isGenericChange(step.name));
  const pool = changes.length ? changes : known;
  let main = pool[0]!;
  for (const step of pool) if (step.count > main.count) main = step;
  return { main, others: pool.length - 1 };
}

const isGenericChange = (name: string) => {
  const action = genericOf(name)?.action;
  return action === "create" || action === "update" || action === "delete";
};

/// One step in words: the table's line (with its count, and the workspace when it names one), or
/// a generic name in the MCP rows' words ("Read workspace", "Updated tab ×2").
function stepLine(t: Translate, step: Step, running: boolean, workspace: string | undefined): string {
  const entry = step.verb;
  if (entry) {
    const line = running ? t(entry.doing) : t(entry.done, { n: step.count });
    return entry.where && workspace ? t("tools.cmux.inWorkspace", { action: line, workspace }) : line;
  }
  const generic = genericOf(step.name)!;
  const line = t(`tools.mcp.${generic.action}`, { target: generic.noun });
  return !running && step.count > 1 ? `${line} ×${step.count}` : line;
}

function withOthers(t: Translate, line: string, others: number): string {
  return others > 0 ? t("tools.cmux.andMore", { action: line, n: others }) : line;
}

/// A `cmux_exec` call's title.
export function execTitle(t: Translate, view: ExecView, running: boolean): string {
  const answer = view.answer;
  if (!running && answer) {
    // The server keeps only the first calls of a long script (`call_log_truncated`): a count from a
    // cut log would be wrong ("Closed 200 tabs" for 250), so such a script says its total instead.
    const complete = !answer.truncated && answer.callLog.length >= answer.calls;
    const picked = complete ? mainStep(finishedSteps(answer.callLog)) : undefined;
    if (picked) return withOthers(t, stepLine(t, picked.main, false, view.workspace), picked.others);
    const first = answer.callLog[0]?.name ?? view.scriptCalls[0];
    if (first) return t("tools.cmux.script", { n: Math.max(answer.calls, 1), first: spoken(first) });
    if (view.docs) return docsLine(t, view.docsQuery, false);
    return t("tools.cmux.scriptBare");
  }
  // Running, or finished without an answer to read (an error the harness wrote as text): the
  // script's own calls, in the tense the call is in.
  const steps = view.scriptCalls.map((name) => ({ name, count: 1, ...(VERBS[name] && { verb: VERBS[name] }) }));
  const picked = mainStep(dedupeSteps(steps));
  if (picked && running) return withOthers(t, stepLine(t, picked.main, true, view.workspace), picked.others);
  const first = view.scriptCalls[0];
  if (!first && view.docs) return docsLine(t, view.docsQuery, running);
  if (running) return first ? t("tools.cmux.runningNamed", { first: spoken(first) }) : t("tools.cmux.running");
  return first ? t("tools.cmux.scriptNamed", { first: spoken(first) }) : t("tools.cmux.scriptBare");
}

/// Script names that share a verb entry, as one step.
function dedupeSteps(steps: Step[]): Step[] {
  const seen = new Set<Verb | string>();
  return steps.filter((step) => {
    const key = step.verb ?? step.name;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function docsLine(t: Translate, query: string | undefined, running: boolean): string {
  const shown = query?.trim();
  if (shown) return t(running ? "tools.cmux.searchingFor" : "tools.cmux.searchedFor", { query: shown });
  return t(running ? "tools.cmux.searching" : "tools.cmux.searched");
}

/// A cached title and the workspace name it was made with: a direct call's title names the
/// workspace the run's names resolve, which can arrive after the row first draws.
const titleCache = new WeakMap<Tool, Map<Translate, { workspace: string | undefined; title: string }>>();

/// The title of one or more consecutive calls to one cmux tool (`calls` and their `tools`, in
/// order), or nil for calls the transcript says as any other MCP call. Kept per call snapshot and
/// language, so a row that draws again reads its title from the cache.
export function cmuxTitle(
  t: Translate,
  calls: readonly McpCall[],
  tools: readonly Tool[],
  names: McpNames = new Map(),
): string | undefined {
  const first = calls[0];
  const tool = tools[0];
  if (!first || !tool || !isCmuxCall(first)) return undefined;
  const one = calls.length === 1;
  const named = first.tool === EXEC || first.tool === DOCS ? undefined : argWorkspace(first.args, names);
  if (one) {
    const cached = titleCache.get(tool)?.get(t);
    if (cached && cached.workspace === named) return cached.title;
  }
  const running = tools.some(isRunningTool);
  let title: string;
  if (first.tool === EXEC) title = execTitle(t, execView(tool, first.args), running);
  else if (first.tool === DOCS) {
    const queries = new Set(calls.map((call) => (isRecord(call.args) ? call.args.query : undefined)));
    const query = queries.size === 1 ? [...queries][0] : undefined;
    title = docsLine(t, typeof query === "string" ? query : undefined, running);
  } else {
    const workspaces = new Set(calls.map((call) => argWorkspace(call.args, names)));
    const workspace = workspaces.size === 1 ? [...workspaces][0] : undefined;
    const entry = VERBS[first.tool];
    title = stepLine(t, { name: first.tool, count: calls.length, ...(entry && { verb: entry }) }, running, workspace);
  }
  if (one) {
    let byLanguage = titleCache.get(tool);
    if (!byLanguage) titleCache.set(tool, (byLanguage = new Map()));
    byLanguage.set(t, { workspace: named, title });
  }
  return title;
}

function parse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

/// What an opened `cmux_exec` row draws, in order (McpCallRows.tsx `CmuxExecDetails`); Find in
/// Chat reads the same text (chatFind.ts).
export type ExecParts = {
  script?: string;
  /// Each tool it called, once, with how many times and how many of those failed.
  calls: { name: string; count: number; failed: number }[];
  result?: TreeLine[];
  error?: TreeLine[];
  logs?: string;
  /// Whether the response is shown as it came instead (no answer to read, or one with a number
  /// a double would round).
  rawResponse: boolean;
};

const partsCache = new WeakMap<ExecView, ExecParts>();

export function execParts(view: ExecView, clean: (text: string) => string): ExecParts {
  const cached = partsCache.get(view);
  if (cached) return cached;
  const answer = view.answer?.exact ? view.answer : undefined;
  const calls = new Map<string, { name: string; count: number; failed: number }>();
  for (const call of answer?.callLog ?? []) {
    const entry = calls.get(call.name) ?? { name: call.name, count: 0, failed: 0 };
    entry.count += 1;
    if (!call.ok) entry.failed += 1;
    calls.set(call.name, entry);
  }
  const shown = (value: unknown) => value !== undefined && value !== null;
  const parts: ExecParts = {
    ...(view.script?.trim() && { script: view.script.replace(/\n$/, "") }),
    calls: [...calls.values()],
    ...(answer && shown(answer.result) && { result: valueTree(answer.result, clean) }),
    ...(answer && shown(answer.error) && { error: valueTree(answer.error, clean) }),
    ...(answer?.logs.length && { logs: answer.logs.join("\n") }),
    rawResponse: !answer,
  };
  partsCache.set(view, parts);
  return parts;
}

/// A called tool's line in the opened row: its name, and how many times it ran.
export const callLine = (call: ExecParts["calls"][number]) =>
  call.count > 1 ? `${call.name} ×${call.count}` : call.name;

/// The text an opened row draws, for Find (the failure counts and heads are not searched).
export function execText(parts: ExecParts, response: string | undefined): string {
  return [
    parts.script,
    parts.calls.map(callLine).join("\n"),
    parts.result && treeText(parts.result),
    parts.error && treeText(parts.error),
    parts.logs,
    parts.rawResponse ? response : undefined,
  ]
    .filter(Boolean)
    .join("\n");
}
