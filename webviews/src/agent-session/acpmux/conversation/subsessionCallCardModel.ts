/// The card's line for a session not waiting: what it does now, or, failed, why. Only a `doing` line
/// that repeats the prompt shown under the card is left out; an error always stays, even one that
/// starts like the prompt (Codex review of #27240), and stands in for a `doing` line left out.
export function sessionLine(
  doing: string | undefined,
  error: string | undefined,
  failed: boolean,
  shown?: string,
): string | undefined {
  const step = doing && !(shown && repeatsPrompt(doing, shown)) ? doing : undefined;
  return step ?? (failed ? error : undefined);
}

/// Whether a session's `doing` line only repeats the start of the prompt shown under it: acpmux
/// names a new session from its prompt, so its first line is that prompt's opening words, often cut
/// with an ellipsis. Compared on words, ignoring whitespace, case and a trailing ellipsis.
export function repeatsPrompt(line: string, prompt: string): boolean {
  // The line as it came first: a prompt may itself start with "Working on:". Then without acpmux's
  // own prefix for a session with no step yet, "Working on: <prompt, cut>" (hub/subsession_send.rs).
  const bare = line.replace(/^\s*Working on:\s*/iu, "");
  return startsPrompt(line, prompt) || (bare !== line && startsPrompt(bare, prompt));
}

/// Whether `line` is the start of `prompt`, word for word, ignoring case and whitespace. Only a line
/// that says it is cut (it ends in an ellipsis) may stop mid-word, so a real step ("Fix bug") never
/// hides behind its prompt ("Fix bugs ...").
function startsPrompt(line: string, prompt: string): boolean {
  const ellipsis = /(?:\.\.\.|\u2026)\s*$/u;
  const cut = ellipsis.test(line);
  const words = (text: string) => text.replace(ellipsis, "").toLowerCase().split(/\s+/u).filter(Boolean);
  const head = words(line);
  if (head.length === 0) return false;
  const body = words(prompt).slice(0, head.length);
  if (body.length < head.length) return false;
  return head.every((word, index) =>
    cut && index === head.length - 1 ? body[index]!.startsWith(word) : body[index] === word,
  );
}
