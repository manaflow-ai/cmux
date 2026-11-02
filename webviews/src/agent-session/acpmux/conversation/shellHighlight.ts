// A shell command's tokens for its Shell block (ShellBlock.tsx): the command name, its flags, quoted
// strings, operators (pipes, `&&`, redirections), variables and `$(…)`, keywords, numbers and
// comments, each in the code color of its role (syntax-theme.ts), as a fenced ```bash block reads.
// Every character of the command is in exactly one token, in order, so the drawn text, its copy and
// Find in Chat read the command unchanged. It runs once per command string (ShellCommand is memoized
// on it), never per streamed chunk of the output under it, and only over the first
// MAX_HIGHLIGHTED_COMMAND characters: a longer tail (a heredoc that writes a big file) draws plain.
import { agentSyntaxColor, SYNTAX_ROLES, type SyntaxRoleName } from "../../../syntax-theme";

export type ShellRole = "command" | "flag" | "string" | "operator" | "variable" | "keyword" | "number" | "comment";
export type ShellToken = { text: string; role?: ShellRole };

/// The longest command head that is tokenized; the rest is one plain token.
export const MAX_HIGHLIGHTED_COMMAND = 20_000;

/// Each shell role's code role: the command as a function call, operators and keywords as keywords,
/// flags as attributes, variables as types (cyan, apart from plain text), as Shiki's shellscript
/// grammar and our token rules color them.
const CODE_ROLE: Record<ShellRole, SyntaxRoleName> = {
  command: "function",
  flag: "attribute",
  string: "string",
  operator: "keyword",
  variable: "type",
  keyword: "keyword",
  number: "constant",
  comment: "comment",
};

/// A role's color: the pane's lifted ANSI slot (`--agent-ansi-N`), the default palette behind it.
/// The slots these roles take are the same in the light and dark defaults.
export const SHELL_ROLE_COLOR: Record<ShellRole, string> = Object.fromEntries(
  Object.entries(CODE_ROLE).map(([role, code]) => [role, agentSyntaxColor(SYNTAX_ROLES[code], "dark", "inherit")]),
) as Record<ShellRole, string>;

const KEYWORDS = new Set(
  "if then else elif fi for while until do done case esac in function select time ! { } [[ ]]".split(" "),
);
/// Commands that run the next word as a command.
const PREFIXES = new Set("sudo exec command builtin nohup xargs env time nice".split(" "));
/// Control operators: the next word starts a command.
const CONTROL = ["&&", "||", ";;", "|&", "|", ";", "&", "(", ")"];
const REDIRECT = /^(\d*)(&>>|&>|>>|>&|<&|>\||<>|>|<)(&?\d+-?|&-)?/;
const HEREDOC = /^(\d*)<<(-?)[ \t]*(['"]?)([A-Za-z_][\w.-]*)\3/;
const ASSIGN = /^[A-Za-z_]\w*(\[[^\]]*\])?\+?=/;
const BREAK = /[\s|&;()<>]/;

/** The command's tokens, adjacent ones of one role merged. */
export function shellTokens(command: string): ShellToken[] {
  const head = command.slice(0, MAX_HIGHLIGHTED_COMMAND);
  const out: ShellToken[] = [];
  lex(head, out);
  if (head.length < command.length) push(out, command.slice(head.length));
  return out;
}

function push(out: ShellToken[], text: string, role?: ShellRole) {
  if (!text) return;
  const last = out[out.length - 1];
  if (last && last.role === role) last.text += text;
  else out.push(role ? { text, role } : { text });
}

/// The end of the quoted string that starts at `at` (its closing quote included), or `limit`.
function quoteEnd(src: string, at: number, limit = src.length): number {
  const quote = src[at]!;
  let i = at + 1;
  while (i < limit && src[i] !== quote) i += quote === '"' && src[i] === "\\" ? 2 : 1;
  return Math.min(i + 1, limit);
}

/// The end of the `$(…)`, `${…}` or backquote group that starts at `at`: past its matching close,
/// skipping quoted text, or `limit`.
function groupEnd(src: string, at: number, open: string, close: string, limit = src.length): number {
  let depth = 0;
  for (let i = at; i < limit; i++) {
    const c = src[i]!;
    if (c === "\\") i++;
    else if ((c === "'" || c === '"') && open !== "`") i = quoteEnd(src, i, limit) - 1;
    else if (c === open && open !== close) depth++;
    else if (c === close && (open === close ? i > at : --depth === 0)) return i + 1;
  }
  return limit;
}

/// How deep `$(…)` inside `$(…)` is highlighted as commands; deeper, one variable-colored run.
const MAX_DEPTH = 8;
let depth = 0;

/// Whether the `$` at `at` starts an expansion (else it is a plain `$`).
const startsExpansion = (src: string, at: number) => /^\$(?:[({']|[A-Za-z_0-9?#@*!$-])/.test(src.slice(at, at + 2));

/// A `$` expansion at `at` (`$NAME`, `$1`, `$?`, `${…}`, `$(…)`, `$((…))`, `$'…'`), none of it past
/// `limit` (the end of the quote or word it is in): pushes it and returns its end.
function expansion(src: string, at: number, out: ShellToken[], limit = src.length): number {
  const name = /^(?:[A-Za-z_]\w*|[0-9?#@*!$-])/.exec(src.slice(at + 1, Math.min(at + 64, limit)));
  const next = at + 1 < limit ? src[at + 1] : undefined;
  if (next !== "(" && next !== "{" && next !== "'" && !name) {
    // Cut at a quote's end: a plain `$`.
    push(out, "$");
    return at + 1;
  }
  if (next === "(") {
    // `$(…)`: its inner command is highlighted as a command; `$((…))` arithmetic (and a substitution
    // nested past MAX_DEPTH) reads as a variable.
    const end = groupEnd(src, at + 1, "(", ")", limit);
    if (src[at + 2] === "(" || depth >= MAX_DEPTH) {
      push(out, src.slice(at, end), "variable");
      return end;
    }
    push(out, "$(", "variable");
    const closed = src[end - 1] === ")";
    depth++;
    try {
      lex(src.slice(at + 2, closed ? end - 1 : end), out);
    } finally {
      depth--;
    }
    if (closed) push(out, ")", "variable");
    return end;
  }
  if (next === "{") {
    const end = groupEnd(src, at + 1, "{", "}", limit);
    push(out, src.slice(at, end), "variable");
    return end;
  }
  if (next === "'") {
    const end = quoteEnd(src, at + 1, limit);
    push(out, src.slice(at, end), "string");
    return end;
  }
  push(out, src.slice(at, at + 1 + name![0].length), "variable");
  return at + 1 + name![0].length;
}

/// A double-quoted string at `at`: green, its `$` expansions in their own color.
function doubleQuoted(src: string, at: number, out: ShellToken[], limit = src.length): number {
  const end = quoteEnd(src, at, limit);
  let from = at;
  for (let i = at + 1; i < end; i++) {
    if (src[i] === "\\") {
      i++;
      continue;
    }
    if (src[i] !== "$" || !startsExpansion(src, i)) continue;
    push(out, src.slice(from, i), "string");
    const after = expansion(src, i, out, end);
    from = after;
    i = after - 1;
  }
  push(out, src.slice(from, end), "string");
  return end;
}

function lex(src: string, out: ShellToken[]) {
  /// The next word starts a command.
  let commandAt = true;
  /// The next word follows a redirection: its target, not an argument.
  let target = false;
  /// Heredocs whose bodies start at the next line: their delimiter and whether `<<-` strips tabs.
  const pending: { delimiter: string; strip: boolean }[] = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i]!;
    if (c === "\n") {
      push(out, c);
      i++;
      commandAt = true;
      // Heredoc bodies, each to its delimiter's own line: text, as a fenced block draws it.
      for (const doc of pending.splice(0)) {
        let line = i;
        while (line < src.length) {
          const stop = src.indexOf("\n", line);
          const end = stop < 0 ? src.length : stop;
          const text = src.slice(line, end);
          if ((doc.strip ? text.replace(/^\t+/, "") : text) === doc.delimiter) {
            push(out, src.slice(i, line), "string");
            push(out, text, "operator");
            i = end;
            break;
          }
          line = end + 1;
          if (stop < 0) {
            push(out, src.slice(i), "string");
            i = src.length;
          }
        }
      }
      continue;
    }
    // Any whitespace BREAK ends a word on (`\r` of a CRLF, `\f`, a no-break space) is stepped over
    // here, or `word` would return where it started and the loop would never end.
    if (/\s/.test(c) || (c === "\\" && src[i + 1] === "\n")) {
      const n = c === "\\" ? 2 : 1;
      push(out, src.slice(i, i + n));
      i += n;
      continue;
    }
    if (c === "#") {
      const stop = src.indexOf("\n", i);
      const end = stop < 0 ? src.length : stop;
      push(out, src.slice(i, end), "comment");
      i = end;
      continue;
    }
    const rest = src.slice(i, i + 64);
    const heredoc = HEREDOC.exec(rest);
    if (heredoc) {
      push(out, heredoc[0], "operator");
      pending.push({ delimiter: heredoc[4]!, strip: heredoc[2] === "-" });
      i += heredoc[0].length;
      continue;
    }
    if (rest.startsWith("<<<")) {
      push(out, "<<<", "operator");
      i += 3;
      target = true;
      continue;
    }
    const redirect = REDIRECT.exec(rest);
    // A digit only leads a redirection at a word's start (`2>&1`, not `a2>b`'s middle).
    if (redirect && (redirect[1] === "" || /^\s?$/.test(src[i - 1] ?? ""))) {
      push(out, redirect[0], "operator");
      i += redirect[0].length;
      // `>&2` and `2>&1` name their target already.
      target = !redirect[3];
      continue;
    }
    const control = CONTROL.find((op) => rest.startsWith(op));
    if (control) {
      push(out, control, "operator");
      i += control.length;
      commandAt = control !== ")";
      target = false;
      continue;
    }
    const read = word(src, i, out, commandAt && !target);
    i = read.end;
    if (target) target = false;
    else commandAt = commandAt && read.keepsCommand;
  }
}

/// Keywords after which the next word is not a command (`for NAME in …`, `case WORD in`).
const NAMING = new Set(["for", "case", "select", "function", "in"]);

/// One word from `at`: pushes its parts and returns its end, and whether a word in command place
/// leaves the next one a command too (an assignment `X=1 cmd`, a flag of a prefix, `sudo`, `then`).
function word(src: string, at: number, out: ShellToken[], commandAt: boolean): { end: number; keepsCommand: boolean } {
  let end = at;
  while (end < src.length && !BREAK.test(src[end]!)) {
    const c = src[end]!;
    if (c === "\\") end += 2;
    else if (c === "'" || c === '"') end = quoteEnd(src, end);
    else if (c === "$" && (src[end + 1] === "(" || src[end + 1] === "{"))
      end = groupEnd(src, end + 1, src[end + 1]!, src[end + 1] === "(" ? ")" : "}");
    else if (c === "`") end = groupEnd(src, end, "`", "`");
    else end++;
  }
  end = Math.min(end, src.length);
  const text = src.slice(at, end);
  let keepsCommand = false;
  // The role of the word's plain text: a command, a keyword, a flag, a number, or none.
  let role: ShellRole | undefined;
  let from = at;
  if (commandAt && text.startsWith("-")) {
    role = "flag";
    keepsCommand = true;
  } else if (commandAt) {
    const assign = ASSIGN.exec(text);
    if (assign) {
      const name = assign[0].replace(/(\[[^\]]*\])?\+?=$/, "");
      push(out, name, "variable");
      push(out, assign[0].slice(name.length));
      from = at + assign[0].length;
      keepsCommand = true;
    } else if (KEYWORDS.has(text)) {
      push(out, text, "keyword");
      return { end, keepsCommand: !NAMING.has(text) };
    } else {
      role = "command";
      keepsCommand = PREFIXES.has(text);
    }
  } else if (/^--?[^-\d]/.test(text) || text === "--") role = "flag";
  else if (/^\d+(\.\d+)?$/.test(text)) role = "number";
  // A flag keeps its value plain (`--name=value`), and quoted or expanded parts their own colors.
  const eq = role === "flag" ? text.indexOf("=") : -1;
  let plainFrom = from;
  const flush = (to: number) => {
    if (to <= plainFrom) return;
    if (eq >= 0 && role === "flag") {
      const cut = Math.max(plainFrom, Math.min(to, at + eq));
      push(out, src.slice(plainFrom, cut), "flag");
      push(out, src.slice(cut, to));
    } else push(out, src.slice(plainFrom, to), role);
  };
  for (let i = from; i < end;) {
    const c = src[i]!;
    if (c === "\\") {
      i = Math.min(i + 2, end);
      continue;
    }
    if (c === "'") {
      flush(i);
      const stop = quoteEnd(src, i, end);
      push(out, src.slice(i, stop), "string");
      i = plainFrom = stop;
      continue;
    }
    if (c === '"') {
      flush(i);
      i = plainFrom = doubleQuoted(src, i, out, end);
      continue;
    }
    if (c === "`") {
      flush(i);
      const stop = groupEnd(src, i, "`", "`", end);
      push(out, src.slice(i, stop), "variable");
      i = plainFrom = stop;
      continue;
    }
    if (c === "$" && startsExpansion(src, i)) {
      flush(i);
      const after = expansion(src, i, out, end);
      i = plainFrom = Math.min(after, end);
      continue;
    }
    i++;
  }
  flush(end);
  return { end, keepsCommand };
}
