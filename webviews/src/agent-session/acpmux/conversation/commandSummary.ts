// What a shell call did, as a row reads it (Leo 2026-10-13): "Fetched feat-cmux-next and diffed
// HEAD~1" for `cd ~/wt/lanes/x && git fetch -q origin feat-cmux-next && git diff HEAD~1 | cut -c1-80`.
// Setup steps (cd, export, a variable) say nothing and drop; a pipe's later stages only shape the
// output and drop too. A command with a step not known here, or more than three steps, has no
// summary: the row then reads "Ran {command}", without its leading cd.
import type { StringKey, Translate } from "../i18n";

type Phrase = { key: StringKey; values?: Record<string, string> };

/// A leading `cd <dir> &&` split off: the folder's last part, and the command that ran there.
export function commandFolder(command: string): { folder?: string; rest: string } {
  const match = /^\s*cd\s+("[^"]+"|'[^']+'|\S+)\s*(?:&&|;)\s*/.exec(command);
  if (!match) return { rest: command };
  const dir = match[1]!.replace(/^["']|["']$/g, "").replace(/\/+$/, "");
  const folder = dir.split("/").at(-1);
  return { folder: folder && folder !== "~" && folder !== "." ? folder : undefined, rest: command.slice(match[0].length) };
}

/// The row's summary, or undefined when the command does not read as known steps.
export function commandSummary(command: string, t: Translate): string | undefined {
  const phrases = commandPhrases(command);
  if (!phrases?.length) return undefined;
  const said = phrases.map((phrase) => t(phrase.key, phrase.values));
  return said.slice(1).reduce((first, next) => t("tools.cmd.and", { first, second: midSentence(next) }), said[0]!);
}

/// "Diffed HEAD~1" after "and" reads "diffed HEAD~1"; "PR #12" and "HEAD" keep their capitals.
function midSentence(phrase: string): string {
  return /^\p{Lu}\p{Ll}/u.test(phrase) ? phrase[0]!.toLocaleLowerCase() + phrase.slice(1) : phrase;
}

export function commandPhrases(command: string): Phrase[] | undefined {
  if (/[`\n]|\$\(/.test(command)) return undefined;
  const phrases: Phrase[] = [];
  for (const step of steps(command)) {
    const words = programWords(step);
    if (!words) continue;
    const phrase = stepPhrase(words);
    if (!phrase) return undefined;
    if (!phrases.some((said) => said.key === phrase.key && said.values?.ref === phrase.values?.ref)) phrases.push(phrase);
  }
  return phrases.length <= 3 ? phrases : undefined;
}

/// Each `&&`, `||` or `;` step, cut at its first pipe, outside quotes.
function steps(command: string): string[] {
  const out: string[] = [];
  let current = "";
  let quote = "";
  let piped = false;
  for (let i = 0; i < command.length; i += 1) {
    const c = command[i]!;
    if (quote) {
      if (c === quote) quote = "";
      if (!piped) current += c;
      continue;
    }
    if (c === "'" || c === '"') {
      quote = c;
      if (!piped) current += c;
    } else if ((c === "&" || c === "|") && command[i + 1] === c) {
      out.push(current);
      current = "";
      piped = false;
      i += 1;
    } else if (c === ";") {
      out.push(current);
      current = "";
      piped = false;
    } else if (c === "|") piped = true;
    else if (!piped) current += c;
  }
  out.push(current);
  return out.map((step) => step.trim()).filter(Boolean);
}

/// A step's program and arguments, without variables set before it and wrappers around it; undefined
/// for a setup step that does nothing to read about.
function programWords(step: string): string[] | undefined {
  const words = (step.match(/"[^"]*"|'[^']*'|\S+/g) ?? []).map((word) => word.replace(/^["']|["']$/g, ""));
  while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0]!)) words.shift();
  for (;;) {
    if (words[0] === "env" || words[0] === "command" || words[0] === "time") words.shift();
    else if (words[0] === "timeout") words.splice(0, 2);
    else if (words[0] === "heavy" && words[1] === "--mem") words.splice(0, 3);
    else break;
  }
  const program = words[0]?.split("/").at(-1);
  if (!program || /^(cd|pushd|popd|export|set|source|\.|true|:|unset|sleep)$/.test(program)) return undefined;
  if (/[<>]/.test(program) || program.startsWith("2>")) return undefined;
  return [program, ...words.slice(1).filter((word) => !/^\d?>/.test(word))];
}

const args = (words: string[]) => words.filter((word) => !word.startsWith("-"));

function stepPhrase([program, ...rest]: string[]): Phrase | undefined {
  switch (program) {
    case "git": {
      // `git -C dir status`: the -C and its folder say nothing more.
      while (rest[0] === "-C" || rest[0] === "-c") rest = rest.slice(2);
      const [verb, ...more] = rest;
      const plain = args(more);
      switch (verb) {
        case "fetch":
          return { key: "tools.cmd.fetched", values: { ref: plain.at(-1) ?? "origin" } };
        case "diff":
          return plain[0] ? { key: "tools.cmd.diffed", values: { ref: plain[0] } } : { key: "tools.cmd.diffedChanges" };
        case "push":
          return { key: "tools.cmd.pushed" };
        case "commit":
          return { key: "tools.cmd.committed" };
        case "status":
          return { key: "tools.cmd.status" };
        case "log":
        case "show":
          return { key: "tools.cmd.log" };
        default:
          return undefined;
      }
    }
    case "ls":
      return { key: "tools.cmd.listed", values: { path: args(rest)[0] ?? "." } };
    case "cat":
    case "head":
    case "tail":
    case "less": {
      const file = args(rest).at(-1);
      return file ? { key: "tools.cmd.read", values: { file: file.split("/").at(-1)! } } : undefined;
    }
    case "rg":
    case "grep": {
      const pattern = args(rest)[0];
      return pattern ? { key: "tools.cmd.searched", values: { pattern } } : undefined;
    }
    case "gh": {
      const number = rest[0] === "pr" && rest[1] === "view" ? args(rest.slice(2))[0] : undefined;
      return number && /^\d+$/.test(number) ? { key: "tools.cmd.pr", values: { number } } : undefined;
    }
    case "bun":
    case "npm":
    case "pnpm":
    case "yarn":
    case "cargo":
    case "swift":
      return rest[0] === "test" || (rest[0] === "run" && rest[1] === "test") ? { key: "tools.cmd.tests" } : undefined;
    case "pytest":
      return { key: "tools.cmd.tests" };
    default:
      return undefined;
  }
}
