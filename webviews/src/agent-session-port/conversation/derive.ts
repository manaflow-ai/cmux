// Turn -> what the Codex desktop transcript shows. Pure functions over protocol.ts items.
//
// The rules mirror the ChatGPT desktop bundle (app.asar, webview/assets):
// - agent-activity-item-*.js `ur()`: which items are groupable, standalone or hidden;
// - inline-followup-markdown-*.js `N()` (consecutive groupable items form one group keyed
//   by its first item), `je()` (summary segment order), `Pe()` (group icon), `Je()` (a
//   one-item group collapses to its row);
// - sites-end-resource-*.js `Y_()` / `nO()` (segment wording, joined as an Intl "unit" list);
// - collapsed-turn-disclosure-*.js ("Worked for {time}" or "{n} previous messages").
// docs/codex-data-model.md lists the evidence; derive.test.ts checks real rollouts.
import { CODEX_TOOL_LABELS } from "./codexTools";
import { netDiffStats } from "./netDiff";
import type {
  AgentMessageItem,
  CommandAction,
  CommandExecutionItem,
  FileChangeItem,
  FileUpdateChange,
  McpToolCallItem,
  ThreadItem,
  Turn,
  UserMessageItem,
  WebSearchThreadItem,
} from "./protocol";

/* ---------------- Display types ---------------- */

/** Leading glyph of an activity row or group header. */
export type ActivityIcon =
  | "globe" // web search
  | "read" // file read (open book)
  | "search" // file search (magnifier)
  | "list" // directory listing (folder)
  | "terminal" // shell command
  | "stopped" // interrupted command
  | "computer" // Computer Use / browser tool call (⌘)
  | "tool" // other tool call
  | "edit" // file change (pencil)
  | "image";

/** Expandable detail under a row. */
export type ActivityBody =
  | { kind: "shell"; command: string; output: string; exitCode: number | null }
  | { kind: "tool-output"; blocks: string[]; raw: boolean }
  | {
      kind: "diff";
      path: string;
      name: string;
      diff: string;
      additions: number;
      deletions: number;
    };

export type ActivityRow = {
  /** Stable id (the protocol item id, `#<n>` appended for multi-file changes). */
  key: string;
  icon: ActivityIcon;
  /** First word(s), full brightness: "Ran", "Read", "Searched the web", "Edited". */
  verb: string;
  /** Rest of the label; `detailTone: "link"` renders it as a file link. */
  detail?: string;
  detailTone?: "plain" | "dim" | "link";
  /** "+12 -2" after a file change. */
  stats?: { additions: number; deletions: number };
  /** Live (in progress) rows are dim and may shimmer. */
  live?: boolean;
  body?: ActivityBody;
};

/** One clause of a group's summary label, in the order the app emits them. */
export type SummaryPart =
  | { kind: "mcp-sources"; sources: string[]; integration: boolean }
  | { kind: "unnamed-mcp-calls"; count: number }
  | { kind: "file-changes"; count: number }
  | { kind: "exploration" }
  | { kind: "commands"; count: number }
  | { kind: "web-search" }
  | { kind: "codex-tool-call"; tool: string; failed: boolean };

export type ActivityUnit =
  /** Commentary between groups ("I'll survey recent primary research …"). */
  | { kind: "message"; key: string; text: string }
  /** Collapsible group of consecutive tool items. */
  | {
      kind: "group";
      key: string;
      label: string;
      icon: ActivityIcon;
      parts: SummaryPart[];
      rows: ActivityRow[];
    }
  /** A tool item shown on its own (one-item group, image view, compaction …). */
  | { kind: "row"; key: string; row: ActivityRow }
  /** Live reasoning heading of an in-progress turn ("Planning sequential file opening …"). */
  | { kind: "thinking"; key: string; label: string };

export type TurnHeader = {
  kind: "worked" | "previous" | "working" | "stopped";
  label: string;
  /** Completed turns fold their activity behind the header. */
  collapsible: boolean;
};

export type TurnView = {
  key: string;
  user: { key: string; text: string } | null;
  header: TurnHeader | null;
  /** Hidden while the header is collapsed. */
  activity: ActivityUnit[];
  /** Final answer(s), always visible. */
  final: { key: string; text: string }[];
  /** "Edited N files" card: net change per file over the turn. */
  edits: { path: string; additions: number; deletions: number }[];
};

export type DeriveOptions = {
  /** Elapsed ms of an in-progress turn ("Working for 42s"). */
  elapsedMs?: number;
  /**
   * The app's own worked-for record of an interrupted turn ("You stopped after {time}"
   * measures from the stop request, not the turn start, so it is not in the protocol).
   */
  stoppedAfterMs?: number;
  /** Workspace root; file paths in the edits card are shown relative to it. */
  cwd?: string;
  /**
   * `history` (default): a reloaded thread, "Worked for" is the turn's duration. `live`: the
   * app watched the turn run and kept a worked-for record from the turn's start to the final
   * answer's first token (`imr()` / `A_r()` in the bundle).
   */
  workedFor?: "history" | "live";
};

/** The "Worked for" time of a completed turn, as the app computes it. */
export function workedForMs(
  turn: Turn,
  mode: DeriveOptions["workedFor"] = "history",
): number | null {
  if (mode === "live" && turn.startedAt != null && turn.finalAnswerStartedAtMs != null)
    return turn.finalAnswerStartedAtMs - turn.startedAt * 1000;
  return turn.durationMs;
}

/* ---------------- Formatting ---------------- */

/** "1m 16s", "42s", "1h 3m"; zero units dropped, under one second is "0s". */
export function formatDuration(ms: number): string {
  const total = Math.floor(ms / 1000);
  if (total <= 0) return "0s";
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return [h && `${h}h`, m && `${m}m`, s && `${s}s`].filter(Boolean).join(" ");
}

const unitList = new Intl.ListFormat("en", { type: "unit" });
const andList = new Intl.ListFormat("en", { type: "conjunction" });
const plural = (n: number, one: string, other: string) => (n === 1 ? one : other);
const capitalize = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const basename = (p: string) => p.slice(p.lastIndexOf("/") + 1);
const oneLine = (s: string) => s.replace(/\s+/g, " ").trim();

/* ---------------- Items -> activity items ---------------- */

type Grouping = "groupable" | "standalone";

/** `ur()`: null hides the item without breaking a group. */
function grouping(item: ThreadItem): Grouping | null {
  switch (item.type) {
    case "commandExecution":
    case "fileChange":
    case "mcpToolCall":
    case "dynamicToolCall":
      return "groupable";
    case "webSearch":
      return item.query.trim() === "" ? null : "groupable";
    case "agentMessage":
    case "imageView":
    case "contextCompaction":
      return "standalone";
    case "userMessage":
    case "reasoning":
    case "plan":
    case "sleep":
      return null;
  }
}

/**
 * The actions a command shows as: its parsed reads / searches / listings when every part
 * of it parsed as one (`cat a; sed -n 1,9p b` reads two files), else one "Ran" action.
 */
function commandActions(item: CommandExecutionItem): CommandAction[] {
  const parsed = item.commandActions;
  return parsed.length > 0 && parsed.every((a) => a.type !== "unknown")
    ? parsed
    : [{ type: "unknown", command: item.command }];
}

const isExploration = (item: ThreadItem) =>
  item.type === "commandExecution" && commandActions(item)[0]!.type !== "unknown";

const CUA_SERVER = "cua_repl";
const CODEX_APP_SERVER = "codex_app";

/** Named source of a tool call (`h()` in the bundle): the browser, an app, or Computer Use. */
function toolSource(item: McpToolCallItem): { key: string; name: string } | null {
  const surface = item.result?._meta?.["codex/toolSurface"];
  if (!surface) return null;
  if (surface.kind === "browserUse") return { key: "browser-use", name: "the browser" };
  if (surface.app) return { key: `app:${surface.app.appId}`, name: capitalize(surface.app.appId) };
  return { key: "computer-use", name: "Computer Use" };
}

/** Computer Use calls without a surface ran plain JS in the REPL; the app counts them as commands. */
const isReplCommand = (item: McpToolCallItem) => item.server === CUA_SERVER && !toolSource(item);

/** Lines added / removed by a unified diff (or a new file's content). */
export function diffStats(change: FileUpdateChange): { additions: number; deletions: number } {
  let additions = 0;
  let deletions = 0;
  for (const line of change.diff.split("\n")) {
    if (line.startsWith("+++") || line.startsWith("---")) continue;
    if (line.startsWith("+")) additions++;
    else if (line.startsWith("-")) deletions++;
  }
  return { additions, deletions };
}

/** Rows of one item (a file change has one row per file). */
export function rowsOf(item: ThreadItem): ActivityRow[] {
  switch (item.type) {
    case "commandExecution": {
      const live = item.status === "inProgress";
      const actions = commandActions(item);
      return actions.map((action, i): ActivityRow => {
        const key = actions.length > 1 ? `${item.id}#${i}` : item.id;
        switch (action.type) {
          case "read":
            return {
              key,
              icon: "read",
              verb: live ? "Reading" : "Read",
              detail: action.name,
              detailTone: "link",
              live,
            };
          case "search": {
            const where = action.path ? ` in ${action.path}` : "";
            const what = action.query ? `for ${action.query}${where}` : `for files${where}`;
            return {
              key,
              icon: "search",
              verb: live ? "Searching" : "Searched",
              detail: what,
              live,
            };
          }
          case "listFiles":
            return {
              key,
              icon: "list",
              verb: live ? "Listing" : "Listed",
              detail: action.path ? `files in ${action.path}` : "files",
              live,
            };
          case "unknown":
            return {
              key,
              icon: item.status === "declined" ? "stopped" : "terminal",
              verb: live ? "Running" : "Ran",
              detail: oneLine(item.command),
              live,
              body: {
                kind: "shell",
                command: item.command,
                output: item.aggregatedOutput ?? "",
                exitCode: item.exitCode,
              },
            };
        }
      });
    }
    case "fileChange":
      return item.changes.map((change, i) => {
        const stats = diffStats(change);
        const verb =
          change.kind.type === "add"
            ? "Created"
            : change.kind.type === "delete"
              ? "Deleted"
              : "Edited";
        return {
          key: item.changes.length > 1 ? `${item.id}#${i}` : item.id,
          icon: "edit" as const,
          verb,
          detail: basename(change.path),
          detailTone: "link" as const,
          stats,
          live: item.status === "inProgress",
          body: {
            kind: "diff" as const,
            path: change.path,
            name: basename(change.path),
            diff: change.diff,
            ...stats,
          },
        };
      });
    case "mcpToolCall": {
      const title = typeof item.arguments?.title === "string" ? item.arguments.title : null;
      const codex = item.server === CODEX_APP_SERVER ? CODEX_TOOL_LABELS[item.tool] : undefined;
      const label = codex
        ? item.status === "failed"
          ? codex.failed
          : item.status === "inProgress"
            ? codex.active
            : codex.completed
        : (title ?? `${item.server}.${item.tool}`);
      const blocks = (item.result?.content ?? []).flatMap((c) =>
        c.type === "text" ? [c.text] : [],
      );
      if (item.error) blocks.push(item.error.message);
      return [
        {
          key: item.id,
          icon: item.server === CUA_SERVER ? "computer" : "tool",
          verb: label,
          live: item.status === "inProgress",
          body: { kind: "tool-output", blocks, raw: true },
        },
      ];
    }
    case "webSearch": {
      const detail = webSearchDetail(item);
      return [
        {
          key: item.id,
          icon: "globe",
          verb: "Searched the web",
          detail: detail ? `for ${detail}` : undefined,
          detailTone: "dim",
        },
      ];
    }
    case "dynamicToolCall":
      return [{ key: item.id, icon: "tool", verb: item.tool, live: item.status === "inProgress" }];
    case "imageView":
      return [
        {
          key: item.id,
          icon: "image",
          verb: "Viewed image",
          detail: basename(item.path),
          detailTone: "link",
        },
      ];
    case "contextCompaction":
      return [{ key: item.id, icon: "tool", verb: "Context automatically compacted" }];
    default:
      return [];
  }
}

/** `eD()`: "site:arxiv.org 2512.24601 …" -> "2512.24601 … | arxiv.org". */
function moveSites(query: string): string {
  const sites: string[] = [];
  const rest = query.replace(/\bsite:([^\s]+)/giu, (whole, host: string) => {
    let name: string;
    try {
      name = new URL(`https://${host}`).hostname.replace(/^www\./u, "");
    } catch {
      return whole;
    }
    if (!sites.includes(name)) sites.push(name);
    return "";
  });
  if (sites.length === 0) return query;
  const text = rest
    .replace(/\bOR\b/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
  return text.length === 0 ? query : `${text} | ${sites.join(" · ")}`;
}

/** `ZE()` / `QE()`: the detail after "Searched the web for". */
export function webSearchDetail(item: WebSearchThreadItem): string {
  const a = item.action;
  const fromAction = (() => {
    switch (a?.type) {
      case "search": {
        const q = a.query?.trim();
        if (q) return moveSites(q);
        const queries = (a.queries ?? []).map((x) => x.trim());
        const first = queries.find((x) => x.length > 0) ?? "";
        return queries.length > 1 && first ? `${moveSites(first)} ...` : moveSites(first);
      }
      case "openPage":
        return a.url ?? "";
      case "findInPage":
        return a.pattern && a.url
          ? `'${a.pattern}' in ${a.url}`
          : a.pattern
            ? `'${a.pattern}'`
            : (a.url ?? "");
      default:
        return "";
    }
  })().trim();
  return fromAction || item.query;
}

/* ---------------- Group summary ---------------- */

/** `je()`: summary clauses in the app's fixed order. */
export function summaryParts(items: ThreadItem[]): SummaryPart[] {
  const parts: SummaryPart[] = [];
  const sources = new Map<string, string>();
  let unnamed = 0;
  let replCommands = 0;
  const codexTools: { tool: string; failed: boolean }[] = [];
  const editedPaths = new Set<string>();
  let explored = false;
  let commands = 0;
  let webSearch = false;
  for (const item of items) {
    switch (item.type) {
      case "mcpToolCall": {
        if (item.server === CODEX_APP_SERVER && CODEX_TOOL_LABELS[item.tool]) {
          if (!codexTools.some((t) => t.tool === item.tool))
            codexTools.push({ tool: item.tool, failed: item.status === "failed" });
          break;
        }
        const source = toolSource(item);
        if (source) sources.set(source.key, source.name);
        else if (isReplCommand(item)) replCommands++;
        else unnamed++;
        break;
      }
      case "fileChange":
        for (const c of item.changes) editedPaths.add(c.path);
        break;
      case "commandExecution":
        if (isExploration(item)) explored = true;
        else commands++;
        break;
      case "webSearch":
        webSearch = true;
        break;
    }
  }
  if (sources.size > 0)
    parts.push({
      kind: "mcp-sources",
      sources: [...sources.values()],
      integration: !sources.has("browser-use"),
    });
  if (unnamed > 0) parts.push({ kind: "unnamed-mcp-calls", count: unnamed });
  if (editedPaths.size > 0) parts.push({ kind: "file-changes", count: editedPaths.size });
  if (explored) parts.push({ kind: "exploration" });
  if (commands + replCommands > 0) parts.push({ kind: "commands", count: commands + replCommands });
  if (webSearch) parts.push({ kind: "web-search" });
  for (const t of codexTools) parts.push({ kind: "codex-tool-call", ...t });
  return parts;
}

/** `Y_()`: one clause, capitalized when it leads the label. */
export function partLabel(part: SummaryPart, leading: boolean): string {
  const text = (() => {
    switch (part.kind) {
      case "mcp-sources": {
        const names = andList.format(part.sources);
        return part.integration
          ? `used ${names} ${plural(part.sources.length, "integration", "integrations")}`
          : `used ${names}`;
      }
      case "unnamed-mcp-calls":
        return plural(part.count, "called a tool", "called tools");
      case "file-changes":
        return plural(part.count, "edited a file", "edited files");
      case "exploration":
        return "read files";
      case "commands":
        return plural(part.count, "ran a command", "ran commands");
      case "web-search":
        return "searched the web";
      case "codex-tool-call": {
        const labels = CODEX_TOOL_LABELS[part.tool];
        if (!labels) return part.tool;
        if (leading) return part.failed ? labels.failed : labels.completed;
        return part.failed ? labels.failedFollowing : labels.following;
      }
    }
  })();
  // Proper names ("the browser", app ids) keep their case; only the leading verb is raised.
  return leading ? capitalize(text) : text;
}

/** The group header label ("Used the browser and Com.cmuxterm.hq, read files, ran commands"). */
export function summaryLabel(parts: SummaryPart[]): string {
  if (parts.length === 0) return "Worked";
  return unitList.format(parts.map((p, i) => partLabel(p, i === 0)));
}

/** `Pe()`: the header glyph is the first clause's representative item's glyph. */
function groupIcon(parts: SummaryPart[], items: ThreadItem[]): ActivityIcon {
  switch (parts[0]?.kind) {
    case "mcp-sources":
      return "computer";
    case "file-changes":
      return "edit";
    case "exploration": {
      const first = items.find(isExploration);
      return first ? (rowsOf(first)[0]?.icon ?? "read") : "read";
    }
    case "commands":
      return "terminal";
    case "web-search":
      return "globe";
    default:
      return "tool";
  }
}

/* ---------------- Turn ---------------- */

const isFinal = (item: ThreadItem): item is AgentMessageItem =>
  item.type === "agentMessage" && item.phase === "final_answer";

/**
 * Net per-file change over the turn, in first-touch order (the "Edited N files" card): the
 * turn's patches to each path composed into one diff (netDiff.ts), so lines a later patch
 * rewrites count once. A path that is moved keeps the summed patch counts (the app bails
 * out of composing renames too), as do patches without hunk positions.
 */
export function turnEdits(items: ThreadItem[], cwd?: string) {
  const files = new Map<string, FileUpdateChange[]>();
  for (const item of items) {
    if (item.type !== "fileChange" || item.status === "failed" || item.status === "declined")
      continue;
    for (const change of item.changes)
      files.set(change.path, [...(files.get(change.path) ?? []), change]);
  }
  return [...files].map(([path, changes]) => {
    const rel = cwd && path.startsWith(`${cwd}/`) ? path.slice(cwd.length + 1) : path;
    const moved = changes.some((c) => c.kind.type === "update" && c.kind.move_path);
    // Patches without hunk headers (hand-built turns) have no positions to compose.
    const positioned = changes.every((c) => /^@@ -\d/m.test(c.diff));
    const stats =
      moved || !positioned
        ? changes.map(diffStats).reduce((x, y) => ({
            additions: x.additions + y.additions,
            deletions: x.deletions + y.deletions,
          }))
        : netDiffStats(
            changes.map((c) => c.diff),
            { created: changes[0]!.kind.type === "add" },
          );
    return { path: rel, ...stats };
  });
}

/** Activity units of a run of items (`N()` + `Je()`). */
export function activityUnits(items: ThreadItem[], { inProgress = false } = {}): ActivityUnit[] {
  const units: ActivityUnit[] = [];
  const groupItems = new Map<string, ThreadItem[]>();
  let pending: ThreadItem[] = [];
  const flush = () => {
    const [first] = pending;
    if (!first) return;
    const rows = pending.flatMap(rowsOf);
    const multiFile = first.type === "fileChange" && first.changes.length > 1;
    if (pending.length === 1 && !multiFile && rows[0]) {
      units.push({ kind: "row", key: first.id, row: rows[0] });
    } else {
      const parts = summaryParts(pending);
      groupItems.set(`agent-activity-group:${first.id}`, pending);
      units.push({
        kind: "group",
        key: `agent-activity-group:${first.id}`,
        label: summaryLabel(parts),
        icon: groupIcon(parts, pending),
        parts,
        rows,
      });
    }
    pending = [];
  };
  for (const item of items) {
    const g = grouping(item);
    if (g === null) continue;
    if (g === "groupable") {
      pending.push(item);
      continue;
    }
    flush();
    if (item.type === "agentMessage")
      units.push({ kind: "message", key: item.id, text: item.text });
    else {
      const [row] = rowsOf(item);
      if (row) units.push({ kind: "row", key: item.id, row });
    }
  }
  flush();
  // A running turn shows its latest tool unit as the one item in progress (`Ye()`), and a
  // trailing reasoning item as its live heading.
  if (inProgress) {
    const lastUnit = units.at(-1);
    if (lastUnit && (lastUnit.kind === "group" || lastUnit.kind === "row")) {
      const unitItems = lastUnit.kind === "group" ? (groupItems.get(lastUnit.key) ?? []) : [];
      const running = [...unitItems].reverse().find(isRunning);
      const row = running
        ? rowsOf(running).at(-1)
        : lastUnit.kind === "row" && lastUnit.row.live
          ? lastUnit.row
          : undefined;
      if (row)
        units[units.length - 1] = { kind: "row", key: lastUnit.key, row: { ...row, live: true } };
    }
    const last = items.at(-1);
    if (last?.type === "reasoning") {
      const heading = last.summary[0]?.match(/\*\*(.+?)\*\*/)?.[1] ?? last.summary[0];
      if (heading) units.push({ kind: "thinking", key: last.id, label: heading });
    }
  } else {
    // A finished (or stopped) turn has no live rows, whatever state its items stopped in.
    for (const u of units) {
      if (u.kind === "group") u.rows = u.rows.map((r) => ({ ...r, live: false }));
      if (u.kind === "row") u.row = { ...u.row, live: false };
    }
  }
  return units;
}

const isRunning = (item: ThreadItem) => ("status" in item && item.status === "inProgress") || false;

function header(turn: Turn, collapsedCount: number, opts: DeriveOptions): TurnHeader | null {
  if (turn.status === "inProgress")
    return {
      kind: "working",
      label: opts.elapsedMs == null ? "Working" : `Working for ${formatDuration(opts.elapsedMs)}`,
      collapsible: false,
    };
  if (turn.status === "interrupted")
    return {
      kind: "stopped",
      label: `You stopped after ${formatDuration(opts.stoppedAfterMs ?? turn.durationMs ?? 0)}`,
      collapsible: false,
    };
  const worked = workedForMs(turn, opts.workedFor);
  if (worked != null)
    return { kind: "worked", label: `Worked for ${formatDuration(worked)}`, collapsible: true };
  return {
    kind: "previous",
    label: `${collapsedCount} ${plural(collapsedCount, "previous message", "previous messages")}`,
    collapsible: true,
  };
}

/**
 * The part of a user message the app shows. The desktop app sends ambient context (the
 * `<in-app-browser-context>` block, files mentioned, comments, …) ahead of a
 * `## My request:` / `## My request for Codex:` header, and the transcript shows only the
 * text after the last such header, trimmed (`fp` in app-shared-*.js).
 */
export function visibleUserText(text: string) {
  const parts = text.split(/## My request(?: for Codex)?:/);
  return parts.length <= 1 ? text : parts[parts.length - 1]!.trim();
}

/** Everything the transcript shows for one turn. */
export function deriveTurn(turn: Turn, opts: DeriveOptions = {}): TurnView {
  const user = turn.items.find((i): i is UserMessageItem => i.type === "userMessage");
  const userText =
    user?.content.flatMap((c) => (c.type === "text" ? [c.text] : [])).join("\n") ?? "";
  const final = turn.items.filter(isFinal);
  const body = turn.items.filter((i) => i.type !== "userMessage" && !isFinal(i));
  const activity = activityUnits(body, { inProgress: turn.status === "inProgress" });
  const collapsedCount = body.filter((i) => grouping(i) !== null).length;
  return {
    key: turn.id,
    user: user ? { key: user.id, text: visibleUserText(userText).replace(/\n+$/, "") } : null,
    header: header(turn, collapsedCount, opts),
    activity,
    final: final.map((m) => ({ key: m.id, text: m.text })),
    edits: turnEdits(turn.items, opts.cwd),
  };
}

/** Web searches of a turn, for callers that list sources. */
export const webSearches = (turn: Turn) =>
  turn.items.filter(
    (i): i is WebSearchThreadItem => i.type === "webSearch" && i.query.trim() !== "",
  );

export type { FileChangeItem };
