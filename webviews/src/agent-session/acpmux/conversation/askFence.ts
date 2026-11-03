// A multiple-choice ask an agent writes into its reply as a ```ask fence (Leo, 2026-11-03: "there's
// a bunch of ad-hoc [outward] or [for you] type things that the coordinator or other sessions do
// and i feel like for multiple choice things like that we can just render something pretty and
// usable"). Unlike AskUserQuestion it never holds the turn: the reply has ended, and a click sends
// the chosen option as the person's next prompt (AskFenceCard.tsx).
//
//   ```ask
//   The ultras session ran about 40 slow Bash calls in the foreground.   <- context (optional)
//   Add a hook that pushes known-slow commands to the background?        <- the question
//   - Yes, add the hook                                                   <- options, 2 to 6
//   - Not now
//   ```
//
// The last line before the options is the question; any lines above it are context. A fence that
// is not this shape stays a code block.

export type AskFence = { context: string[]; question: string; options: string[] };

const OPTION = /^\s*(?:[-*+]|\d{1,2}[.)])\s+(.+?)\s*$/;
export const MAX_ASK_OPTIONS = 6;

export const isAskLang = (lang: string | undefined): boolean => lang?.trim().toLowerCase() === "ask";

/// The fence's ask, or undefined when it is not one (no question, fewer than 2 or more than 6
/// options, or prose after the options).
export function parseAskFence(code: string): AskFence | undefined {
  const lines = code.split("\n");
  const prose: string[] = [];
  const options: string[] = [];
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    const option = OPTION.exec(raw);
    if (option) options.push(option[1]!);
    else if (options.length > 0) return undefined;
    else prose.push(line);
  }
  const question = prose.pop();
  if (!question || options.length < 2 || options.length > MAX_ASK_OPTIONS) return undefined;
  if (new Set(options).size !== options.length) return undefined;
  return { context: prose, question, options };
}
