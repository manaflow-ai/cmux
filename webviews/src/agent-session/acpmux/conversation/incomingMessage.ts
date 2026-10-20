// A prompt that is not the person's words: another agent's message, or harness bookkeeping in the
// prompt's text. acpmux marks a message it delivered (`_meta.provenance` kind `agent_message`,
// prompt_provenance.rs: `send_to_session`, `cmux agent message`). Claude Code writes its own into
// the prompt, which reaches the pane only in an adopted Claude session's history (acpmux records
// those prompts with `client: "adopt"`, hub/adoption.rs): a `<cross-session-message>` from another
// session, a `<task-notification>` when a background task ends, and reminders and caveats the
// person never typed. The transcript draws a message as a card from its sender
// (IncomingMessageCard.tsx), a notification as one quiet line, and bookkeeping not at all; a typed
// prompt behind bookkeeping draws without it. A live prompt's text is the person's as typed.

export type IncomingMessage = {
  /// The sender's name, or its address when it gives none.
  name: string;
  /// The sending chat, when it is one here that can be opened.
  sessionId?: string;
  /// The message's id and its thread's (the `agent_message` provenance), which a reply names
  /// (IncomingMessageCard.tsx's Reply); a Claude Code envelope has neither.
  msgId?: string;
  threadId?: string;
  /// What the sender wrote.
  text: string;
  /// The prompt as the agent got it.
  raw: string;
};

export type IncomingPrompt =
  | { kind: "message"; message: IncomingMessage }
  | { kind: "notice"; text: string }
  /// Bookkeeping only: no row.
  | { kind: "hidden" }
  /// The person's prompt, without the bookkeeping before it.
  | { kind: "prompt"; text: string };

/// What a `user_message` is when not the person's own as recorded, or undefined when it is.
export function incomingPrompt(
  text: string,
  msg: { _meta?: { provenance?: unknown }; client?: unknown } | undefined,
): IncomingPrompt | undefined {
  const provenance = msg?._meta?.provenance as Record<string, unknown> | undefined;
  if (provenance?.kind === "agent_message" && typeof provenance.from === "string" && provenance.from) {
    const name =
      typeof provenance.fromName === "string" && provenance.fromName.trim()
        ? provenance.fromName.trim()
        : provenance.from;
    const id = (key: string) =>
      typeof provenance[key] === "string" && provenance[key] ? { [key]: provenance[key] as string } : {};
    return {
      kind: "message",
      message: { name, sessionId: provenance.from, ...id("msgId"), ...id("threadId"), text: text.trim(), raw: text },
    };
  }
  if (msg?.client !== "adopt") return undefined;
  // Claude Code's envelopes start the prompt; one quoted later in it is the person's text.
  const rest = withoutBookkeeping(text);
  const envelope = CROSS_SESSION.exec(rest);
  if (envelope) {
    const attributes = envelope[1]!;
    const name = attribute(attributes, "from-name") || attribute(attributes, "from");
    // What follows the envelope is Claude Code's note to the agent about it.
    if (name) return { kind: "message", message: { name, text: decodeXml(envelope[2]!).trim(), raw: text } };
  }
  const notification = NOTIFICATION.exec(rest);
  if (notification && !withoutBookkeeping(rest.slice(notification[0].length))) {
    const summary = tag(notification[0], "summary") || tag(notification[0], "status");
    return summary ? { kind: "notice", text: summary } : { kind: "hidden" };
  }
  if (!rest) return { kind: "hidden" };
  return rest === text.trim() ? undefined : { kind: "prompt", text: rest };
}

/// `<cross-session-message from="…" from-name="…" from-mode="…">body</cross-session-message>`,
/// closed by the first closing tag.
const CROSS_SESSION = /^<cross-session-message((?:\s+[\w-]+="[^"]*")*)\s*>([\s\S]*?)<\/cross-session-message>/;
const NOTIFICATION = /^<task-notification>[\s\S]*?<\/task-notification>/;
/// Bookkeeping Claude Code puts in a prompt (transcript.ts `CLAUDE_HIDDEN_USER_TAGS`), whole.
const BOOKKEEPING = /^<(system-reminder|local-command-caveat|user-prompt-submit-hook)>[\s\S]*?<\/\1>/;

/// The text after the bookkeeping blocks it starts with, trimmed.
function withoutBookkeeping(text: string): string {
  let rest = text.trim();
  for (let block = BOOKKEEPING.exec(rest); block; block = BOOKKEEPING.exec(rest))
    rest = rest.slice(block[0].length).trim();
  return rest;
}

function attribute(attributes: string, name: string): string {
  return decodeXml(new RegExp(`(?:^|\\s)${name}="([^"]*)"`).exec(attributes)?.[1] ?? "").trim();
}

function tag(text: string, name: string): string {
  return decodeXml(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(text)?.[1] ?? "").trim();
}

function decodeXml(text: string): string {
  return text.replace(
    /&(?:(lt|gt|quot|apos|amp)|#(\d+)|#x([0-9a-f]+));/gi,
    (whole, name?: string, dec?: string, hex?: string) => {
      if (name)
        return ({ lt: "<", gt: ">", quot: '"', apos: "'", amp: "&" } as Record<string, string>)[name.toLowerCase()]!;
      const code = dec ? Number(dec) : parseInt(hex!, 16);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    },
  );
}
