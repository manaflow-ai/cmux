// A prompt that is not the person's words: another agent's message, or harness bookkeeping in the
// prompt's text. acpmux marks a message it delivered (`_meta.provenance` kind `agent_message`,
// prompt_provenance.rs: `send_to_session`, `cmux agent message`). Claude Code writes its own into
// the prompt (an adopted Claude session's history): a `<cross-session-message>` from another
// session, a `<task-notification>` when a background task ends, and reminders and caveats the
// person never typed. The transcript draws a message as a card from its sender
// (IncomingMessageCard.tsx), a notification as one quiet line, and the rest not at all.

export type IncomingMessage = {
  /// The sender's name, or its address when it gives none.
  name: string;
  /// The sending chat, when it is one here that can be opened.
  sessionId?: string;
  /// What the sender wrote.
  text: string;
  /// The prompt as the agent got it.
  raw: string;
};

export type IncomingPrompt =
  | { kind: "message"; message: IncomingMessage }
  | { kind: "notice"; text: string }
  | { kind: "hidden" };

/// What a `user_message` is when not the person's own, or undefined for the person's prompt.
export function incomingPrompt(text: string, meta: { provenance?: unknown } | undefined): IncomingPrompt | undefined {
  const provenance = meta?.provenance as Record<string, unknown> | undefined;
  if (provenance?.kind === "agent_message" && typeof provenance.from === "string" && provenance.from) {
    const name =
      typeof provenance.fromName === "string" && provenance.fromName.trim()
        ? provenance.fromName.trim()
        : provenance.from;
    return {
      kind: "message",
      message: {
        name,
        sessionId: provenance.from,
        text: text.trim(),
        raw: text,
      },
    };
  }
  // Claude Code's envelopes start the prompt; one quoted later in it is the person's text.
  const start = text.trimStart();
  const envelope = CROSS_SESSION.exec(start);
  if (envelope) {
    const attributes = envelope[1]!;
    const name = attribute(attributes, "from-name") || attribute(attributes, "from");
    if (name)
      return {
        kind: "message",
        message: { name, text: decodeXml(envelope[2]!).trim(), raw: text },
      };
  }
  if (start.startsWith("<task-notification>")) {
    const summary = tag(start, "summary") || tag(start, "status");
    return summary ? { kind: "notice", text: summary } : { kind: "hidden" };
  }
  if (HIDDEN.test(start)) return { kind: "hidden" };
  return undefined;
}

/// `<cross-session-message from="…" from-name="…" from-mode="…">body</cross-session-message>`,
/// closed by the first closing tag. What follows it is the harness's note to the agent.
const CROSS_SESSION = /^<cross-session-message((?:\s+[\w-]+="[^"]*")*)\s*>([\s\S]*?)<\/cross-session-message>/;
/// Bookkeeping Claude Code adds to a prompt (transcript.ts `CLAUDE_HIDDEN_USER_TAGS`).
const HIDDEN = /^<(system-reminder|local-command-caveat|user-prompt-submit-hook)>/;

function attribute(attributes: string, name: string): string {
  return decodeXml(new RegExp(`(?:^|\\s)${name}="([^"]*)"`).exec(attributes)?.[1] ?? "").trim();
}

function tag(text: string, name: string): string {
  return decodeXml(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(text)?.[1] ?? "").trim();
}

function decodeXml(text: string): string {
  return text.replace(
    /&(lt|gt|quot|apos|#39|amp);/g,
    (_, name: string) => ({ lt: "<", gt: ">", quot: '"', apos: "'", "#39": "'", amp: "&" })[name] ?? "",
  );
}
