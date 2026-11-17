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
  "bat",
  "less",
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
  "export",
  "source",
  "alias",
  "unalias",
  "unset",
  "exit",
  "clear",
  "jobs",
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
  "ping",
  "dig",
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
  "gem",
  "bundle",
  "rake",
  "rails",
  "go",
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
  "code",
  "zed",
  "subl",
  "tmux",
  "zsh",
  "bash",
  "sh",
  "fish",
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
  "composer",
  "perl",
  "lua",
  "zig",
  "nix",
  "just",
  "eza",
  "exa",
  "lsd",
  "cmux",
  "lsof",
  "kill",
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
]);

/// Agent CLIs: their bare name starts that agent's chat in the page (launchRows.ts).
const AGENT_COMMANDS = new Set(["claude", "codex", "opencode", "gemini", "aider", "amp", "cursor-agent", "goose"]);

/// Shell syntax a sentence does not have: pipes, `&&`, redirects, `$VAR`, `$(…)`, backticks.
const SHELL_SYNTAX = /(\|\||&&|[|;<>`]|\$\(|\$[A-Za-z_{])/;
/// `VAR=value` before a command.
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=\S*$/;
/// A word that only a command line has: a flag, a relative or home path.
const SHELL_WORD = /^(-{1,2}[A-Za-z0-9]|\.{1,2}\/|~\/|\/)/;

/// The words of a command line, `sudo` and leading `VAR=value` set aside.
function commandWords(text: string): string[] {
  const words = text.split(/\s+/).filter(Boolean);
  let start = 0;
  while (start < words.length - 1 && (words[start] === "sudo" || ASSIGNMENT.test(words[start]!))) start += 1;
  return words.slice(start);
}

/// How `text` reads, for the Run row. `agents` are the harness ids the page can start; `recent` are
/// command lines the host sent (`omnibar.commands`).
export function commandLikeness(
  text: string,
  context: { agents?: readonly string[]; recent?: readonly string[] } = {},
): CommandLikeness {
  const line = text.trim();
  // A prompt on many lines, an attachment's token, or a question is words for the agent.
  if (!line || /[\n\r]/.test(line) || line.includes(INLINE_ATTACHMENT_MARK)) return "prose";
  if (context.recent?.some((command) => command === line)) return "command";
  const words = commandWords(line);
  const first = words[0]!.toLowerCase();
  const syntax = SHELL_SYNTAX.test(line) || words.slice(1).some((word) => SHELL_WORD.test(word));
  const question = line.endsWith("?");
  // `./build.sh`, `../bin/x`: a path run as a program. A bare `/path` is an address (newTabIntent).
  if (first.startsWith("./") || first.startsWith("../")) return "command";
  if (AGENT_COMMANDS.has(first) || context.agents?.includes(first)) {
    if (syntax) return "command";
    return words.length === 1 ? "agent" : "prose";
  }
  if (COMMANDS.has(first)) {
    if (syntax) return "command";
    if (question) return "maybe";
    return words.length <= 6 ? "command" : "maybe";
  }
  if (AMBIGUOUS.has(first)) {
    if (syntax) return "command";
    if (question) return "prose";
    if (words.length <= 2) return "command";
    return words.length === 3 ? "maybe" : "prose";
  }
  // An unknown program with shell syntax (`foo --bar`, `mytool | head`): maybe.
  return syntax && !question && words.length <= 8 ? "maybe" : "prose";
}

/// Whether `text` is more than one line: a prompt, with fewer rows under it.
export function isMultiline(text: string): boolean {
  return /[\n\r]/.test(text.trim());
}
