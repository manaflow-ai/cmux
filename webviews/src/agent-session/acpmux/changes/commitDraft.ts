// The commit bar's Draft (cx-tcwj): the agent reads what is staged and replies with a message the
// user edits before Commit. The prompt goes to the agent, like the review bar's revert prompt.

export const COMMIT_DRAFT_PROMPT = [
  "Write a commit message for the changes staged in this repository (`git diff --cached`).",
  "Don't commit, stage or edit anything.",
  "Reply with only the message: a summary line of at most 72 characters, then a blank line and a short body if the change needs one.",
].join(" ");

/// The message in the agent's reply: the reply itself, or the inside of the one code block it
/// wrapped the message in.
export function commitMessageFromReply(reply: string): string {
  const text = reply.trim();
  const fenced = /^```[^\n]*\n([\s\S]*?)\n```$/.exec(text);
  return (fenced ? fenced[1]! : text).trim();
}

/// The text of the last agent reply after row `from` (the agent may say what it will do before it
/// reads the diff), or "" when there is none.
export function replyAfter(rows: readonly { kind: string; text?: string }[], from: number): string {
  return (
    rows
      .slice(from)
      .reverse()
      .find((row) => row.kind === "assistant")?.text ?? ""
  );
}
