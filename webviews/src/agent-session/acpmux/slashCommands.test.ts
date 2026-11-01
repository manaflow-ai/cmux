import { describe, expect, test } from "bun:test";
import {
  commandSplice,
  slashMatches,
  slashNames,
  slashTokens,
  slashTrigger,
  SLASH_WORD_MAX,
  type SlashCommand,
} from "./slashCommands";

// cmux's own commands, two harness built-ins (untagged, `agent`), a skill and a prompt.
const commands: SlashCommand[] = [
  { name: "model", description: "", source: "cmux" },
  { name: "fork", description: "", source: "cmux" },
  { name: "compact", description: "Clear the history but keep a summary", source: "agent" },
  { name: "review", description: "Review a pull request", source: "agent" },
  { name: "review-pr", description: "Review a pull request", source: "skill" },
  { name: "release", description: "", source: "skill" },
  { name: "refactor", description: "", source: "prompt" },
];

describe("slashTrigger: where the `/` menu opens", () => {
  test("a `/word` that is the prompt's first word leads", () => {
    expect(slashTrigger("/", 0)).toEqual({ query: "", length: 1, leading: true });
    expect(slashTrigger("/rev", 0)).toEqual({ query: "rev", length: 4, leading: true });
    // After an attachment or spaces send takes out: the first word still.
    expect(slashTrigger("\uFFFC /rev", 2)).toEqual({ query: "rev", length: 4, leading: true });
  });

  test("after a space or a line break further on it opens mid-prompt", () => {
    expect(slashTrigger("fix it /", 0)).toEqual({ query: "", length: 1, leading: false });
    expect(slashTrigger("fix it /re", 0)).toEqual({ query: "re", length: 3, leading: false });
    expect(slashTrigger("fix it\n/re", 0)).toEqual({ query: "re", length: 3, leading: false });
    // A later block's start (a new paragraph after words) is mid-prompt too.
    expect(slashTrigger("/re", undefined)).toEqual({ query: "re", length: 3, leading: false });
    // Right after an attachment placed in the text.
    expect(slashTrigger("see \uFFFC/re", 0)?.query).toBe("re");
  });

  test("a `/` inside a word, a path or a URL opens nothing", () => {
    expect(slashTrigger("src/app", 0)).toBeUndefined();
    expect(slashTrigger("open http://x/y", 0)).toBeUndefined();
    expect(slashTrigger("a/b", 0)).toBeUndefined();
    expect(slashTrigger("a/", 0)).toBeUndefined();
    // Mid-prompt a second `/` makes the word a path.
    expect(slashTrigger("look in /usr/lo", 0)).toBeUndefined();
  });

  test("the caret leaving the word closes it", () => {
    // A space after the word, or the caret before its `/`.
    expect(slashTrigger("fix it /review ", 0)).toBeUndefined();
    expect(slashTrigger("fix it ", 0)).toBeUndefined();
    expect(slashTrigger("", 0)).toBeUndefined();
  });

  test("a word longer than any command opens nothing", () => {
    expect(slashTrigger(`x /${"a".repeat(SLASH_WORD_MAX)}`, 0)).toBeUndefined();
    expect(slashTrigger(`/${"a".repeat(SLASH_WORD_MAX - 1)}`, 0)?.leading).toBe(true);
  });
});

describe("slashMatches: what the menu lists", () => {
  const names = (trigger: Parameters<typeof slashMatches>[1]) =>
    slashMatches(commands, trigger).map((match) => match.command.name);

  test("at the prompt's start every command, cmux's own and the harness's built-ins included", () => {
    expect(names({ query: "", length: 1, leading: true })).toEqual(commands.map((command) => command.name));
  });

  test("mid-prompt only skills and prompts: built-ins and cmux's own run only from the start", () => {
    expect(names({ query: "", length: 1, leading: false })).toEqual(["review-pr", "release", "refactor"]);
    expect(names({ query: "mo", length: 3, leading: false })).toEqual([]);
    expect(names({ query: "comp", length: 5, leading: false })).toEqual([]);
    expect(names({ query: "re", length: 3, leading: false })).toEqual(["review-pr", "release", "refactor"]);
  });
});

describe("commandSplice: a pick writes `/name ` over the typed word", () => {
  const pick = (before: string, after: string, name: string, cut = false) => {
    const trigger = slashTrigger(before, 0)!;
    const splice = commandSplice(after, trigger, name, cut);
    const start = before.length - splice.back;
    return {
      text: before.slice(0, start) + splice.text + after.slice(splice.forward),
      caret: start + splice.text.length,
    };
  };

  test("mid-prompt the text before and after stays", () => {
    expect(pick("fix the build then /rev", " it", "review-pr")).toEqual({
      text: "fix the build then /review-pr it",
      caret: "fix the build then /review-pr ".length,
    });
    expect(pick("fix /re", "", "review-pr")).toEqual({ text: "fix /review-pr ", caret: 15 });
  });

  test("the rest of the word after the caret goes, a line break after it stays", () => {
    expect(pick("fix /re", "vxx later", "review-pr").text).toBe("fix /review-pr later");
    expect(pick("fix /re", "\nnext", "review-pr").text).toBe("fix /review-pr \nnext");
    expect(pick("fix /re", "\uFFFC", "review-pr").text).toBe("fix /review-pr \uFFFC");
  });

  test("a rest of the word longer than the read is left whole, never cut", () => {
    const rest = `${"a".repeat(SLASH_WORD_MAX)}\u{1F600}`;
    // Only the first SLASH_WORD_MAX + 1 characters are read: the cut falls inside the emoji.
    const read = rest.slice(0, SLASH_WORD_MAX + 1);
    const picked = pick("fix /re", read, "review-pr", true);
    expect(picked.text).toBe(`fix /review-pr ${read}`);
    expect(pick("fix /re", "vxx", "review-pr", true).text).toBe("fix /review-pr vxx");
  });

  test("at the start it is the old leading pick", () => {
    expect(pick("/mo", "", "model")).toEqual({ text: "/model ", caret: 7 });
  });
});

describe("slashTokens: which `/name` words draw blue", () => {
  const names = slashNames(commands);
  const words = (text: string, lead: number | null = 0) =>
    slashTokens(text, names, { lead: lead ?? undefined }).tokens.map(([from, to]) => text.slice(from, to));

  test("a skill or prompt, at the start or mid-prompt", () => {
    expect(words("/review-pr now")).toEqual(["/review-pr"]);
    expect(words("fix it then /review-pr it")).toEqual(["/review-pr"]);
    expect(words("fix\n/release")).toEqual(["/release"]);
  });

  test("an unknown word or a prefix stays plain", () => {
    expect(words("/revie now")).toEqual([]);
    expect(words("fix /nope")).toEqual([]);
  });

  test("inside a path or a URL never", () => {
    expect(words("src/review-pr")).toEqual([]);
    expect(words("http://x/review-pr")).toEqual([]);
    expect(words("/review-pr/x")).toEqual([]);
  });

  test("cmux's own commands and harness built-ins only as the prompt's first word", () => {
    expect(words("/model opus")).toEqual(["/model"]);
    expect(words("/compact now")).toEqual(["/compact"]);
    expect(words(" \uFFFC /compact", 3)).toEqual(["/compact"]);
    expect(words("then /model and /compact")).toEqual([]);
    expect(words("/model", null)).toEqual([]);
  });

  test("a scan limited to an edit reads only the words it touches", () => {
    const text = "/review-pr a b /release";
    const near = slashTokens(text, names, { lead: 0, from: 22, to: 22 });
    expect(near.tokens.map(([from, to]) => text.slice(from, to))).toEqual(["/release"]);
    expect(near.from).toBe(15);
    // A word cut by the window's edge is not read.
    expect(slashTokens("review-pr", names, { cutStart: true }).tokens).toEqual([]);
    expect(slashTokens("/review-p", names, { cutEnd: true }).tokens).toEqual([]);
  });
});
