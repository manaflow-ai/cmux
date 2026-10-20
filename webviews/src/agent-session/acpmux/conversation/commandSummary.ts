// What a shell call did, as a row reads it (Leo 2026-10-13): "Fetched feat-cmux-next and diffed
// HEAD~1" for `cd ~/wt/lanes/x && git fetch -q origin feat-cmux-next && git diff HEAD~1 | cut -c1-80`.
// Setup steps (cd, export, a variable) say nothing and drop; a pipe into a reader (head, cut, grep,
// ...) only shapes the output and drops too. It fails closed: a pipe into anything else (xargs, sh)
// or a reader told to write (`sort -o`), a redirect, a background `&`, a `||` (its right side may
// not run), a backslash, an option it does not know, a step not known here, or more than three
// steps leaves no summary, and the row reads "Ran {command}" without its leading cd. A
// summary that claims what the command did not do is worse than the command itself.
import { currentLanguage, type StringKey, type Translate } from "../i18n";

type Phrase = { key: StringKey; values?: Record<string, string> };

/// Leading `cd <dir> &&` steps split off: the last folder's last part, and the command that ran
/// there. `cd ..`, `cd ~` and `cd -` name no folder, so the command keeps its prefix: nothing it
/// ran is ever hidden.
export function commandFolder(command: string): { folder?: string; rest: string } {
  let rest = command;
  let dir: string | undefined;
  for (;;) {
    const match = /^\s*cd\s+("[^"]+"|'[^']+'|\S+)\s*(?:&&|;)\s*/.exec(rest);
    if (!match) break;
    dir = match[1]!.replace(/^["']|["']$/g, "").replace(/\/+$/, "");
    rest = rest.slice(match[0].length);
  }
  const folder = dir?.split("/").at(-1);
  return folder && !["~", ".", "..", "-"].includes(folder) ? { folder, rest } : { rest: command };
}

/// The row's summary, or undefined when the command does not read as known steps.
export function commandSummary(command: string, t: Translate): string | undefined {
  const phrases = commandPhrases(command);
  if (!phrases?.length) return undefined;
  const said = phrases.map((phrase) => t(phrase.key, phrase.values));
  return said.slice(1).reduce((first, next) => t("tools.cmd.and", { first, second: midSentence(next) }), said[0]!);
}

/// In English, "Diffed HEAD~1" after "and" reads "diffed HEAD~1" ("PR #12" and "HEAD" keep their
/// capitals). Other languages keep the phrase as written: a German noun or a file name that leads
/// it keeps its case.
function midSentence(phrase: string): string {
  return currentLanguage().startsWith("en") && /^\p{Lu}\p{Ll}/u.test(phrase)
    ? phrase[0]!.toLocaleLowerCase() + phrase.slice(1)
    : phrase;
}

export function commandPhrases(command: string): Phrase[] | undefined {
  if (/[`\n\\]|\$\(|<\(/.test(command)) return undefined;
  const split = steps(command);
  if (!split) return undefined;
  const phrases: Phrase[] = [];
  for (const [first, ...piped] of split) {
    if (piped.some((stage) => !readsOnly(programWords(stage)))) return undefined;
    const words = programWords(first!);
    if (words === null) return undefined;
    if (!words) continue;
    const phrase = stepPhrase(words);
    if (!phrase) return undefined;
    const same = (said: Phrase) =>
      said.key === phrase.key && JSON.stringify(said.values) === JSON.stringify(phrase.values);
    if (!phrases.some(same)) phrases.push(phrase);
  }
  return phrases.length <= 3 ? phrases : undefined;
}

/// Programs a pipe can end in without doing more than shaping what it reads.
const READERS = new Set(["head", "tail", "cut", "wc", "sort", "uniq", "grep", "rg", "jq", "tr", "column", "cat", "nl"]);

/// A pipe stage that only shapes what it reads: a reader not told to write a file (`sort -o out`,
/// `uniq in out`).
function readsOnly(words: string[] | undefined | null): boolean {
  if (!words || !READERS.has(words[0]!)) return false;
  const args = words.slice(1);
  if (words[0] === "sort" && args.some((word) => word.startsWith("--output") || /^-[^-]*o/.test(word))) return false;
  if (words[0] === "uniq" && args.filter((word) => !word.startsWith("-")).length > 1) return false;
  return true;
}

/// Each `&&` or `;` step as its pipe stages, outside quotes; undefined for a background `&` or a
/// `||`, whose right side may not have run.
function steps(command: string): string[][] | undefined {
  const out: string[][] = [];
  let stages: string[] = [];
  let current = "";
  let quote = "";
  const end = () => {
    stages.push(current.trim());
    current = "";
  };
  for (let i = 0; i < command.length; i += 1) {
    const c = command[i]!;
    if (quote) {
      if (c === quote) quote = "";
      current += c;
    } else if (c === "'" || c === '"') {
      quote = c;
      current += c;
    } else if (c === "|" && command[i + 1] === "|") return undefined;
    else if (c === "&" && command[i + 1] === "&") {
      end();
      out.push(stages);
      stages = [];
      i += 1;
    } else if (c === ";") {
      end();
      out.push(stages);
      stages = [];
    } else if (c === "|") end();
    else if (c === "&" && command[i - 1] !== ">" && command[i + 1] !== ">") return undefined;
    else current += c;
  }
  end();
  out.push(stages);
  return out.filter((step) => step[0]);
}

/// Redirects that only quiet a step.
const QUIET = /^(?:\d?>&\d|&?\d?>\/dev\/null)$/;

/// A step's program and arguments, without variables set before it and wrappers around it;
/// undefined for a setup step that does nothing to read about, null for a step that writes or
/// reads through a redirect.
function programWords(step: string): string[] | undefined | null {
  const raw = (step.match(/"[^"]*"|'[^']*'|\S+/g) ?? []).filter((word) => !QUIET.test(word));
  if (raw.some((word) => !/^["']/.test(word) && /[<>]/.test(word))) return null;
  const words = raw.map((word) => word.replace(/^["']|["']$/g, ""));
  while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0]!)) words.shift();
  for (;;) {
    if (words[0] === "env" || words[0] === "command" || words[0] === "time") words.shift();
    else if (words[0] === "timeout") words.splice(0, 2);
    else if (words[0] === "heavy" && words[1] === "--mem") words.splice(0, 3);
    else break;
  }
  const program = words[0]?.split("/").at(-1);
  if (!program || /^(cd|pushd|popd|export|set|source|\.|true|:|unset|sleep)$/.test(program)) return undefined;
  return [program, ...words.slice(1)];
}

/// The arguments that are not options, when every option is one it knows: `flags` take no value,
/// `valued` take the next word (or the rest of theirs), `long` are `--name` or `--name=value`, and
/// `numbers` allows `-20` (head and tail). Undefined for any other option, so an option's value is
/// never read as a file or a pattern.
function positional(
  words: string[],
  {
    flags = "",
    valued = "",
    long = [],
    numbers = false,
  }: { flags?: string; valued?: string; long?: string[]; numbers?: boolean },
): string[] | undefined {
  const out: string[] = [];
  for (let i = 0; i < words.length; i += 1) {
    const word = words[i]!;
    if (word === "--") return [...out, ...words.slice(i + 1)];
    if (word.startsWith("--")) {
      if (!long.includes(word.slice(2).split("=")[0]!)) return undefined;
    } else if (word.startsWith("-") && word.length > 1) {
      if (numbers && /^-\d+$/.test(word)) continue;
      const letters = word.slice(1);
      if (valued.includes(letters[0]!)) {
        if (letters.length === 1) i += 1;
      } else if (!letters.split("").every((letter) => flags.includes(letter))) return undefined;
    } else out.push(word);
  }
  return out;
}

function stepPhrase([program, ...rest]: string[]): Phrase | undefined {
  switch (program) {
    case "git": {
      // `git -C dir status`: the -C and its folder say nothing more.
      while (rest[0] === "-C" || rest[0] === "-c") rest = rest.slice(2);
      const [verb, ...more] = rest;
      switch (verb) {
        case "fetch": {
          const plain = positional(more, {
            flags: "qvpPat",
            long: ["quiet", "prune", "all", "tags", "no-tags", "verbose"],
          });
          return plain && { key: "tools.cmd.fetched", values: { ref: plain.at(-1) ?? "origin" } };
        }
        case "diff": {
          const plain = positional(more, {
            flags: "wR",
            long: [
              "stat",
              "name-only",
              "name-status",
              "cached",
              "staged",
              "shortstat",
              "numstat",
              "color",
              "no-color",
              "quiet",
              "exit-code",
            ],
          });
          if (!plain) return undefined;
          return plain[0] ? { key: "tools.cmd.diffed", values: { ref: plain[0] } } : { key: "tools.cmd.diffedChanges" };
        }
        // A dry run, or an option it does not know, pushed or committed nothing it can say.
        case "push":
          return positional(more, {
            flags: "uqvf",
            long: ["set-upstream", "quiet", "verbose", "force-with-lease", "tags"],
          })
            ? { key: "tools.cmd.pushed" }
            : undefined;
        case "commit":
          return positional(more, {
            flags: "aqsSm",
            valued: "mF",
            long: ["all", "quiet", "amend", "no-edit", "signoff"],
          })
            ? { key: "tools.cmd.committed" }
            : undefined;
        case "status":
          return { key: "tools.cmd.status" };
        case "log":
        case "show":
          return { key: "tools.cmd.log" };
        default:
          return undefined;
      }
    }
    case "ls": {
      const plain = positional(rest, { flags: "laAhRtrSd1F", long: ["all", "color"] });
      return plain && plain.length <= 1 ? { key: "tools.cmd.listed", values: { path: plain[0] ?? "." } } : undefined;
    }
    case "cat":
    case "head":
    case "tail":
    case "less": {
      const plain = positional(rest, {
        flags: "nqvfbsAE",
        valued: "c" + (program === "cat" ? "" : "n"),
        numbers: true,
      });
      return plain?.length === 1
        ? { key: "tools.cmd.read", values: { file: plain[0]!.split("/").at(-1)! } }
        : undefined;
    }
    case "rg":
    case "grep": {
      const plain = positional(rest, {
        flags: "rRnilcwvFEHhsqoLxSuU",
        long: ["hidden", "no-ignore", "ignore-case", "fixed-strings", "files-with-matches", "line-number", "count"],
      });
      return plain?.[0] ? { key: "tools.cmd.searched", values: { pattern: plain[0] } } : undefined;
    }
    case "gh": {
      const number = rest[0] === "pr" && rest[1] === "view" ? rest[2] : undefined;
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
