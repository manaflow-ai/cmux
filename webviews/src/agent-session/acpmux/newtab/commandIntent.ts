// Whether the New Tab field's text reads as a shell command (Lucas 2026-11-17): `ls`, `cd ~/fun`
// or `git status` gets a "Run in Terminal" row, so the person needs no `!` first. Pure and
// synchronous: the page asks on every keystroke, from word lists only, with no disk or host call.
import { INLINE_ATTACHMENT_MARK } from "../attachments";

/// How the text reads.
/// - `command`: a command. Its Run row leads, above Ask.
/// - `maybe`: a command or a prompt (`open the settings`). Its Run row comes second.
/// - `agent`: an agent's CLI named alone (`claude`). Its starts lead, then the Run row.
/// - `prose`: not a command. No Run row.
export type CommandLikeness = "command" | "maybe" | "agent" | "prose";

/// Programs and shell builtins that are almost never the first word of a prompt.
const COMMANDS = new Set([
  "ls",
  "ll",
  "la",
  "cd",
  "pwd",
  "mkdir",
  "rmdir",
  "rm",
  "mv",
  "cp",
  "ln",
  "cat",
  "grep",
  "rg",
  "fd",
  "fzf",
  "sed",
  "awk",
  "uniq",
  "wc",
  "tr",
  "xargs",
  "tee",
  "echo",
  "printf",
  "env",
  "alias",
  "unalias",
  "fg",
  "bg",
  "killall",
  "pkill",
  "pgrep",
  "ps",
  "htop",
  "btop",
  "du",
  "df",
  "uptime",
  "whoami",
  "chmod",
  "chown",
  "chgrp",
  "stat",
  "tar",
  "zip",
  "unzip",
  "gzip",
  "gunzip",
  "curl",
  "wget",
  "ssh",
  "scp",
  "rsync",
  "nslookup",
  "git",
  "gh",
  "npm",
  "npx",
  "pnpm",
  "pnpx",
  "yarn",
  "bun",
  "bunx",
  "deno",
  "node",
  "python",
  "python3",
  "pip",
  "pip3",
  "uv",
  "uvx",
  "poetry",
  "ruby",
  "rails",
  "cargo",
  "rustc",
  "rustup",
  "swift",
  "swiftc",
  "xcodebuild",
  "xcrun",
  "xcode-select",
  "cmake",
  "ninja",
  "brew",
  "docker",
  "docker-compose",
  "kubectl",
  "helm",
  "terraform",
  "aws",
  "gcloud",
  "vercel",
  "wrangler",
  "flyctl",
  "heroku",
  "vim",
  "nvim",
  "vi",
  "nano",
  "emacs",
  "zed",
  "subl",
  "tmux",
  "zsh",
  "bash",
  "sh",
  "sudo",
  "pbcopy",
  "pbpaste",
  "defaults",
  "launchctl",
  "caffeinate",
  "jq",
  "yq",
  "psql",
  "mysql",
  "sqlite3",
  "redis-cli",
  "java",
  "javac",
  "mvn",
  "gradle",
  "dotnet",
  "php",
  "perl",
  "lua",
  "zig",
  "nix",
  "eza",
  "exa",
  "lsd",
  "lsof",
  "ffmpeg",
  "tsc",
  "vite",
  "pytest",
  "jest",
  "vitest",
  "eslint",
  "prettier",
  "biome",
  "nohup",
  "chsh",
  "openssl",
  "base64",
  "shasum",
  "md5",
  "realpath",
  "dirname",
  "basename",
  "mktemp",
  "sw_vers",
  "uname",
  "hostname",
]);

/// Programs whose name is also a common English word: a command when short, a prompt when long.
const AMBIGUOUS = new Set([
  "make",
  "open",
  "find",
  "sort",
  "cut",
  "history",
  "top",
  "which",
  "type",
  "man",
  "touch",
  "file",
  "watch",
  "diff",
  "head",
  "tail",
  "more",
  "tree",
  "date",
  "cal",
  "time",
  "say",
  "set",
  "test",
  "just",
  "go",
  "code",
  "clear",
  "exit",
  "source",
  "export",
  "bundle",
  "kill",
  "ping",
  "dig",
  "less",
  "rake",
  "gem",
  "composer",
  "bat",
  "fish",
  "jobs",
]);

/// Agent CLIs: their bare name starts that agent's chat in the page (launchRows.ts).
const AGENT_COMMANDS = new Set(["claude", "codex", "opencode", "gemini", "aider", "amp", "cursor-agent", "goose"]);

/// Shell operators a sentence does not have: `|`, `||`, `&&`, a redirect, `$VAR`, `$(…)`. Not backticks,
/// `;` or a lone `<`/`>`: a prompt quotes code and writes "a > b".
const SHELL_OPERATOR = /(\|\||&&|\s\|\s|\s\d?>>?\s|\$\(|\$[A-Za-z_{])/;
/// `VAR=value` before a command.
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=\S*$/;
/// A flag: `-l`, `--force`.
const FLAG = /^-{1,2}[A-Za-z0-9]/;
/// A path argument: `.`, `./x`, `../x`, `~/x`, `/x`.
const PATH = /^(\.{1,2}(\/|$)|~\/|\/)/;
/// Words a sentence has and a command line almost never does: "git is slow", "go to the settings".
const PROSE_WORDS = new Set([
  "a",
  "an",
  "the",
  "is",
  "are",
  "was",
  "were",
  "be",
  "been",
  "to",
  "and",
  "or",
  "but",
  "of",
  "for",
  "with",
  "in",
  "on",
  "into",
  "from",
  "it",
  "this",
  "that",
  "my",
  "me",
  "i",
  "we",
  "you",
  "your",
  "why",
  "how",
  "what",
  "not",
  "isn't",
  "doesn't",
  "don't",
  "can't",
  "won't",
  "should",
  "please",
  "so",
  "if",
  "when",
  "all",
]);

/// The words of a command line, `sudo` and leading `VAR=value` set aside.
function commandWords(text: string): string[] {
  const words = text.split(/\s+/).filter(Boolean);
  let start = 0;
  while (start < words.length - 1 && (words[start] === "sudo" || ASSIGNMENT.test(words[start]!))) start += 1;
  return words.slice(start);
}

/// How `text` reads, for the Run row. `agents` are the harness ids the page can start; `recent` are
/// command lines the host sent (`omnibar.commands`). It errs toward the prompt: a Run row that leads
/// runs on Return, so only a line that reads as nothing but a command leads with it.
export function commandLikeness(
  text: string,
  context: { agents?: readonly string[]; recent?: readonly string[] } = {},
): CommandLikeness {
  const line = text.trim();
  // A prompt on many lines or with an attachment's token is words for the agent.
  if (!line || /[\n\r]/.test(line) || line.includes(INLINE_ATTACHMENT_MARK)) return "prose";
  if (context.recent?.some((command) => command === line)) return "command";
  // A question is never run, whatever it names ("which file handles /api?").
  if (line.endsWith("?")) return "prose";
  const words = commandWords(line);
  const first = words[0]!.toLowerCase();
  const rest = words.slice(1);
  const operator = SHELL_OPERATOR.test(line);
  const flag = rest.some((word) => FLAG.test(word));
  const prose = rest.some((word) => PROSE_WORDS.has(word.toLowerCase().replace(/[,.!:]+$/, "")));
  // A path makes a short line a command ("cd ~/fun", "open ."), never a sentence that names one.
  const shaped = operator || flag || (!prose && words.length <= 3 && rest.some((word) => PATH.test(word)));
  // `./build.sh`, `../bin/x`: a path run as a program. A bare `/path` is an address (newTabIntent).
  if (first.startsWith("./") || first.startsWith("../")) return "command";
  // An agent's name with a folder ("codex ~/fun/cmux") starts that agent there (launchRows.ts).
  if (AGENT_COMMANDS.has(first) || context.agents?.includes(first)) {
    if (operator || flag) return "command";
    return words.length === 1 ? "agent" : "prose";
  }
  if (COMMANDS.has(first)) {
    if (shaped) return "command";
    return prose || words.length > 5 ? "maybe" : "command";
  }
  if (AMBIGUOUS.has(first)) {
    if (shaped) return "command";
    if (prose) return "prose";
    if (words.length === 1) return "command";
    return words.length === 2 ? "maybe" : "prose";
  }
  // An unknown program with shell syntax (`mytool --verbose`, `mytool | head`): maybe.
  return (operator || flag) && !prose && words.length <= 6 ? "maybe" : "prose";
}

/// Whether `text` is more than one line: a prompt, with fewer rows under it.
export function isMultiline(text: string): boolean {
  return /[\n\r]/.test(text.trim());
}
