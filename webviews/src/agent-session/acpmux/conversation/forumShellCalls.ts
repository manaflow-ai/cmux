// A shell call to the agent forum's CLI (`agent-forum search|show|list|ask|post|reply|topic|close`),
// read into the same ForumCall the cmux-forum MCP server's calls give (forumCalls.ts), so ForumCallCard
// draws it in place of the raw shell row. Leo, 2026-11-22 07:44Z: "you guys are also using the
// forum? or not as much? i wonder if that's also grounds for a new type of tool call appearance in
// the gui".
//
// Agents mostly reach the forum through the CLI (leo-workspace tools/agent_forum.py, on PATH as
// `agent-forum`), so those calls arrive as shell commands and their text answer is stdout:
//   search: `#N [kind, state] title  (YYYY-MM-DD)` per hit, each followed by `    snippet`
//   list:   the same lines without snippets
//   show:   that line, `  URL  by USER, labels ...`, a blank line, the body, `--- user date` per comment
//   ask, post, topic: `posted #N: TITLE` then `  URL`; reply: `replied on #N: URL`
//   close:  `answered and closed #N`, or `answered #N; not closed: why`
// A `hosted` or `hq` mark may lead `#N`. `--json` prints the same as JSON, read the same way.
//
// Only a call that is one forum command claims a card: `cd DIR &&` before it and output filters
// after it (`| head`, `| tail`, `| cut`, `| sed -n`, `| grep`) are fine, since what the call printed
// is still the forum's answer. A forum command chained with others (`a; agent-forum show 1; b`)
// printed more than the forum's answer and keeps its shell row. Off by default: the
// `forum-call-card` experiment (forumCall.experiment.ts), Settings > Customize "Forum Commands as
// Cards". The MCP server's calls draw their card either way.
import type { AcpmuxActivity } from "../model";
import { safeHref } from "../replyHref";
import { experimentArm } from "../../../experiments/experiment";
import { forumCallLook, type ForumCallLook } from "./forumCall.experiment";
import type { ForumCall, ForumThreadRef, ForumTool } from "./forumCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const ACTIONS = new Set<ForumTool>(["search", "show", "list", "ask", "post", "reply", "close"]);
const FILTERS = /^(?:head|tail|cut|grep|rg|sed|cat)$/;
const LINE = /^(hosted|hq)?#(\d+) \[([^,\]]+), ([^\]]+)\] (.*?) {2}\((\d{4}-\d{2}-\d{2})\)\s*$/;
const POSTED = /^posted (hosted|hq)?#(\d+)(?: \(topic [^)]*\))?: (.+)$/;
const REPLIED = /^replied on (hosted|hq)?#(\d+)(?: \(topic [^)]*\))?: ?(\S*)/;
const CLOSED = /^answered and closed (hosted|hq)?#(\d+)/;
const ANSWERED = /^answered (hosted|hq)?#(\d+); not closed: (.*)$/;
const REFUSED =
  /^agent-forum: nothing filed, open thread (hosted|hq)?#(\d+) asks this already: (.*?)(?: \((https:\/\/\S+)\))?$/;
const MAX_HITS = 20;
const BODY_LINES = 3;

/// The forum call a tool call makes, when the `forum-call-card` experiment draws one (its arm is
/// not `off`), else undefined: the call keeps its shell row.
export function forumShellCallShown(item: AcpmuxActivity, look: ForumCallLook = experimentArm(forumCallLook)) {
  if (look === "off") return undefined;
  return item.tool ? forumShellCall(item.tool) : undefined;
}

/// The forum call shell call `tool` makes, or undefined for any other call.
export function forumShellCall(tool: Tool): ForumCall | undefined {
  const parsed = tool.command ? forumCommand(tool.command) : undefined;
  if (!parsed) return undefined;
  const running = tool.status === "pending" || tool.status === "in_progress";
  const output = running ? "" : (tool.output ?? "");
  const exitFailed = tool.status === "failed" || (typeof tool.exitCode === "number" && tool.exitCode !== 0);
  const call: ForumCall = {
    tool: parsed.action,
    status: running ? "running" : exitFailed ? "failed" : "done",
    query: parsed.query,
    body: parsed.body,
    hits: [],
    thread: parsed.thread,
  };
  if (running) return call;
  // Output that filled what a `head`/`tail` keeps, or went through any other filter, may be cut.
  if (parsed.keeps !== undefined) {
    const printed = output.replace(/\n$/, "").split("\n").length;
    if (parsed.keeps === Infinity || printed >= parsed.keeps) call.partial = true;
  }
  const json = parsed.json ? parseJSON(output) : undefined;
  if (isRecord(json)) readJSON(call, json);
  else readText(call, output);
  // A finished call that printed nothing the card can read (a filter cut it all, or a thread that is not
  // there) still names what it did; a failed one says why in the CLI's own words.
  if (call.status === "failed" && !call.error) call.error = errorLine(output);
  // A cut answer's count is what the filter kept: the card names none.
  if (call.partial && call.thread) call.thread.comments = undefined;
  return call;
}

type ParsedCommand = {
  action: ForumTool;
  json: boolean;
  /// The most lines the output filters after the command keep (`| head -5`: 5), or Infinity for
  /// a filter that may drop any line (`| grep x`); undefined when none.
  keeps?: number;
  query?: string;
  body?: string;
  thread?: ForumThreadRef;
};

/// The forum command a shell command line is, or undefined when it is anything else (or more).
export function forumCommand(command: string): ParsedCommand | undefined {
  // A heredoc gives the words posted on stdin (`--body - <<'EOF'`): its text is the body.
  let line = command.trim();
  let stdin: string | undefined;
  const heredoc = /<<-?\s*(['"]?)([A-Za-z_]\w*)\1[ \t]*\n/.exec(line);
  if (heredoc) {
    const head = line.slice(0, heredoc.index);
    if (head.includes("\n")) return undefined;
    const rest = line.slice(heredoc.index + heredoc[0].length).split("\n");
    const end = rest.findIndex((l) => l.trim() === heredoc[2]);
    if (end < 0 || rest.slice(end + 1).some((l) => l.trim())) return undefined;
    stdin = rest.slice(0, end).join("\n");
    line = head;
  }
  const segments = shellSegments(line);
  if (!segments) return undefined;
  // `cd DIR &&` (or `cd DIR;`) before the call changes nothing it prints.
  let at = 0;
  while (
    at < segments.length - 1 &&
    segments[at]!.words[0] === "cd" &&
    (segments[at]!.op === "&&" || segments[at]!.op === ";")
  )
    at++;
  const chain = segments.slice(at);
  // One forum command, then only output filters, each piped.
  if (!chain.length || chain.slice(0, -1).some((s) => s.op !== "|") || chain.at(-1)!.op) return undefined;
  if (chain.slice(1).some((s) => !FILTERS.test(s.words[0] ?? ""))) return undefined;
  const parsed = forumArgs(chain[0]!.words, stdin);
  if (parsed && chain.length > 1) parsed.keeps = Math.min(...chain.slice(1).map((s) => linesKept(s.words)));
  return parsed;
}

function forumArgs(words: string[], stdin: string | undefined): ParsedCommand | undefined {
  let at = 0;
  while (at < words.length && /^[A-Za-z_]\w*=/.test(words[at]!)) at++;
  // `timeout 60 agent-forum ...`: a deadline on the call, as agents give one.
  if (words[at] === "timeout" && /^\d+(?:\.\d+)?[smh]?$/.test(words[at + 1] ?? "")) at += 2;
  const program = words[at] ?? "";
  if (/(?:^|\/)(?:agent-forum|agent_forum\.py)$/.test(program)) at += 1;
  else if (/^(?:\S*\/)?python3?$/.test(program) && /(?:^|\/)agent_forum\.py$/.test(words[at + 1] ?? "")) at += 2;
  else return undefined;
  let json = false;
  const positional: string[] = [];
  const flags: Record<string, string> = {};
  let action: ForumTool | undefined;
  for (let i = at; i < words.length; i++) {
    const word = words[i]!;
    if (word === "--json") json = true;
    else if (word.startsWith("--")) {
      const eq = word.indexOf("=");
      const name = eq > 0 ? word.slice(2, eq) : word.slice(2);
      if (["body", "kind", "limit"].includes(name)) flags[name] = eq > 0 ? word.slice(eq + 1) : (words[++i] ?? "");
      else if (!["open", "anyway", "no-memory"].includes(name)) return undefined;
    } else if (/^\d*>/.test(word) || /^\d*>&\d$/.test(word)) continue;
    else if (!action) {
      if (!ACTIONS.has(word as ForumTool) && word !== "topic") return undefined;
      action = word === "topic" ? "post" : (word as ForumTool);
      if (word === "topic") flags.topic = "1";
    } else positional.push(word);
  }
  if (!action) return undefined;
  const text = (value: string | undefined) => (value === "-" ? stdin : value)?.trim() || undefined;
  switch (action) {
    case "search":
      return { action, json, query: positional.join(" ") || undefined };
    case "list":
      return { action, json, query: flags.kind };
    case "show":
      return { action, json, thread: threadRef(positional[0]) };
    case "reply":
    case "close":
      return { action, json, thread: threadRef(positional[0]), body: text(positional[1]) };
    case "ask":
      return { action, json, thread: { title: positional[0], kind: "question" }, body: text(flags.body) };
    case "post": {
      // topic KEY TITLE: posts the thread, or replies on the key's open one (the answer says which).
      const title = flags.topic ? positional[1] : positional[0];
      return { action, json, thread: { title, kind: flags.kind }, body: text(flags.body) };
    }
  }
}

/// The lines `head -N`/`tail -N` keep (10 by default), or Infinity for any other filter: what
/// `grep`, `sed`, `cut` drop is not a count of lines.
function linesKept(words: string[]): number {
  if (words[0] !== "head" && words[0] !== "tail") return Infinity;
  const at = words.findIndex((w, i) => i > 0 && /^-(?:n)?\d+$|^-n$|^--lines(?:=\d+)?$/.test(w));
  if (at < 0) return words.length > 1 ? Infinity : 10;
  const word = words[at]!;
  const inline = /(\d+)$/.exec(word);
  const n = Number(inline ? inline[1] : words[at + 1]);
  return Number.isFinite(n) && n > 0 ? n : Infinity;
}

function threadRef(word: string | undefined): ForumThreadRef | undefined {
  const match = word ? /^(hosted|hq)?#?(\d+)$/.exec(word) : undefined;
  return match ? { number: Number(match[2]), mark: match[1] } : undefined;
}

type Segment = { words: string[]; op?: "|" | "&&" | "||" | ";" };

/// A command line's simple commands and the operator after each, or undefined for what this does not
/// read: command substitution, subshells, a background `&`, more than one line.
function shellSegments(line: string): Segment[] | undefined {
  const segments: Segment[] = [];
  let words: string[] = [];
  let word = "";
  let inWord = false;
  const endWord = () => {
    if (inWord) words.push(word);
    word = "";
    inWord = false;
  };
  const endSegment = (op?: Segment["op"]) => {
    endWord();
    if (!words.length) return false;
    segments.push({ words, op });
    words = [];
    return true;
  };
  for (let i = 0; i < line.length; i++) {
    const c = line[i]!;
    if (c === "'") {
      const close = line.indexOf("'", i + 1);
      if (close < 0) return undefined;
      word += line.slice(i + 1, close);
      inWord = true;
      i = close;
    } else if (c === '"') {
      let j = i + 1;
      for (; j < line.length && line[j] !== '"'; j++) {
        if (line[j] === "\\" && j + 1 < line.length) word += line[++j];
        else if (line[j] === "`" || (line[j] === "$" && line[j + 1] === "(")) return undefined;
        else word += line[j];
      }
      if (j >= line.length) return undefined;
      inWord = true;
      i = j;
    } else if (c === "\\" && i + 1 < line.length) {
      word += line[++i];
      inWord = true;
    } else if (c === " " || c === "\t") endWord();
    else if (c === "\n" || c === "`" || c === "(" || c === ")" || (c === "$" && line[i + 1] === "(")) return undefined;
    else if (c === "|" || c === ";" || c === "&") {
      // `2>&1` is a redirect, not an operator.
      if (c === "&" && line[i - 1] === ">") {
        word += c;
        inWord = true;
        continue;
      }
      const two = line.slice(i, i + 2);
      const op = two === "||" || two === "&&" ? two : c === "&" ? undefined : (c as "|" | ";");
      if (!op || !endSegment(op)) return undefined;
      if (op.length === 2) i++;
    } else {
      word += c;
      inWord = true;
    }
  }
  endWord();
  if (words.length) segments.push({ words });
  else if (segments.at(-1)?.op && segments.at(-1)!.op !== ";") return undefined;
  else if (segments.at(-1)?.op === ";") segments.at(-1)!.op = undefined;
  return segments.length ? segments : undefined;
}

/// The CLI's text answer, read into `call`.
function readText(call: ForumCall, output: string) {
  const lines = output.split("\n");
  const first = (re: RegExp) => {
    for (const l of lines) {
      const m = re.exec(l.trim());
      if (m) return m;
    }
    return undefined;
  };
  const refused = first(REFUSED);
  if (refused) {
    call.refused = true;
    call.status = "failed";
    call.thread = { mark: refused[1], number: Number(refused[2]), title: refused[3], url: https(refused[4]) };
    return;
  }
  switch (call.tool) {
    case "search":
    case "list": {
      for (let i = 0; i < lines.length && call.hits.length < MAX_HITS; i++) {
        // The agent-memory hits after the forum's are not threads.
        if (/^(?:agent-memory \(|also: agent-memory)/.test(lines[i]!)) break;
        const hit = lineThread(lines[i]!);
        if (!hit) continue;
        const next = lines[i + 1];
        if (call.tool === "search" && next && /^ {4}\S/.test(next)) hit.snippet = next.trim();
        call.hits.push(hit);
      }
      return;
    }
    case "show": {
      const at = lines.findIndex((l) => LINE.test(l));
      if (at >= 0) call.thread = { ...call.thread, ...lineThread(lines[at]!) };
      const by = at >= 0 ? /^ {2}(\S+) {2}by /.exec(lines[at + 1] ?? "") : undefined;
      if (by && call.thread) call.thread.url = https(by[1]);
      const comments = lines.filter((l) => /^--- \S+ \S+/.test(l)).length;
      if (call.thread && (at >= 0 || comments)) call.thread.comments = comments;
      // The body: the lines after the blank one under the header, up to the first comment.
      if (at >= 0) {
        const body: string[] = [];
        for (const l of lines.slice(at + 3)) {
          if (/^--- \S+ \S+/.test(l)) break;
          if (l.trim()) body.push(l.trim());
          if (body.length >= BODY_LINES) break;
        }
        if (body.length) call.body = body.join("\n");
      }
      return;
    }
    case "ask":
    case "post": {
      const posted = first(POSTED);
      const replied = posted ? undefined : first(REPLIED);
      if (posted) {
        const url = lines.find((l) => /^ {2}https:\/\//.test(l))?.trim();
        call.thread = { ...call.thread, mark: posted[1], number: Number(posted[2]), title: posted[3], url: https(url) };
      } else if (replied) {
        // topic: the key had an open thread, so the post went there as a reply.
        call.tool = "reply";
        call.thread = { mark: replied[1], number: Number(replied[2]), url: https(replied[3]) };
      }
      return;
    }
    case "reply": {
      const replied = first(REPLIED);
      if (replied)
        call.thread = { ...call.thread, mark: replied[1], number: Number(replied[2]), url: https(replied[3]) };
      return;
    }
    case "close": {
      const answered = first(ANSWERED);
      if (answered) {
        call.stillOpen = true;
        call.thread = { ...call.thread, mark: answered[1], number: Number(answered[2]) };
      }
      const closed = first(CLOSED);
      if (closed) call.thread = { ...call.thread, mark: closed[1], number: Number(closed[2]), state: "closed" };
      return;
    }
  }
}

/// The CLI's `--json` answer, read into `call`.
function readJSON(call: ForumCall, data: Record<string, unknown>) {
  if (typeof data.error === "string" && data.error) {
    call.status = "failed";
    call.error = data.error.slice(0, 200);
  }
  if (data.refused === true && isRecord(data.duplicate)) {
    call.refused = true;
    call.status = "failed";
    call.thread = threadOf(data.duplicate);
    return;
  }
  const list = (value: unknown) =>
    (Array.isArray(value) ? value : []).filter(isRecord).slice(0, MAX_HITS).map(threadOf);
  if (call.tool === "search") call.hits = list(data.hits);
  else if (call.tool === "list") call.hits = list(data.threads);
  else if (call.tool === "show" && isRecord(data.issue)) {
    call.thread = threadOf(data.issue);
    if (Array.isArray(data.comments)) call.thread.comments = data.comments.length;
    const body = str(data.issue.body);
    if (body)
      call.body = body
        .split("\n")
        .map((l) => l.trim())
        .filter(Boolean)
        .slice(0, BODY_LINES)
        .join("\n");
  } else if (isRecord(data.created)) {
    call.thread = { ...call.thread, ...threadOf(data.created) };
  } else if (isRecord(data.comment)) {
    if (call.tool !== "close") call.tool = "reply";
    const url = https(str(data.comment.html_url));
    if (url) call.thread = { ...call.thread, url };
    if (call.tool === "close") {
      call.stillOpen = data.closed === false;
      if (data.closed === true && call.thread) call.thread.state = "closed";
    }
  }
}

function lineThread(line: string): ForumThreadRef | undefined {
  const m = LINE.exec(line);
  if (!m) return undefined;
  return { mark: m[1], number: Number(m[2]), kind: m[3], state: m[4], title: m[5], updated: m[6] };
}

function threadOf(raw: Record<string, unknown>): ForumThreadRef {
  const number =
    typeof raw.number === "number" && Number.isInteger(raw.number) && raw.number > 0 ? raw.number : undefined;
  return {
    number,
    mark: raw.source === "hosted" ? "hosted" : undefined,
    title: str(raw.title),
    kind: str(raw.kind),
    state: str(raw.state),
    comments: typeof raw.comments === "number" && Number.isFinite(raw.comments) ? raw.comments : undefined,
    url: https(str(raw.url) ?? str(raw.html_url)),
    snippet: str(raw.snippet),
    updated: str(raw.updated_at)?.slice(0, 10),
  };
}

/// Tool output is untrusted: only an https link is drawn (`safeHref`), never `javascript:`.
function https(url: string | undefined): string | undefined {
  const href = url ? safeHref(url) : undefined;
  return href?.startsWith("https://") ? href : undefined;
}

/// The CLI's own line of why (`agent-forum: ...`), else the output's first line.
function errorLine(output: string): string | undefined {
  const lines = output
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
  const own = lines.find((l) => l.startsWith("agent-forum: "));
  const line = (own ? own.slice("agent-forum: ".length) : lines[0])?.trim();
  return line ? line.slice(0, 200) : undefined;
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJSON(text: string): unknown {
  const trimmed = text.trim();
  if (!trimmed.startsWith("{")) return undefined;
  try {
    return JSON.parse(trimmed);
  } catch {
    return undefined;
  }
}
