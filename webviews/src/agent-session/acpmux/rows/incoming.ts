// A user row's prompt as the view reads it (decision 244). The row's `incoming` holds only what
// the record proves; the page keeps v1's readings of the text (a relay label, a signature, a
// message addressed to a chat first) as this one function over the row's `incoming`, its text and
// the page's chat list, with `incomingPrompt`'s precedence. A text reading only adds typing: it
// never names a sender the record did not. The same gate as v1's (direct.ts, the user row) decides
// `author`, `viaCli`, `sentFrom` and `agentText`: a prompt read as another agent's carries none of
// the person's.
import type { AcpmuxRow } from "../model";
import { noticeRowText } from "../conversation/agentNotice";
import { inboxText } from "../conversation/inboxNotice";
import { type IncomingContext, type IncomingPrompt, incomingPrompt } from "../conversation/incomingMessage";

/// What the record proves of who sent a prompt (the translator's `user.rs` `sender`): the kind, and
/// for another agent's message the sender as far as acpmux proved it.
export type IncomingProof = {
  kind: "message" | "inbox" | "hidden";
  sender?: { name?: string; harness?: string; relay?: string; unverified?: boolean };
};

/// The user row body's fields the reading takes (FIELDS.md, AcpmuxRow).
export type UserBody = {
  content?: string;
  incoming?: IncomingProof;
  viaCli?: string;
  author?: AcpmuxRow["author"];
  sentFrom?: AcpmuxRow["sentFrom"];
  agentText?: AcpmuxRow["agentText"];
};

/// How the prompt reads. With no proof, the text is read as v1 reads a record with none: a row's
/// `viaCli` is the host of the CLI that sent it (`cliHost`), which is what the reading asks of the
/// record. With one, its kind decides: an inbox notice's threads and a message's words are read from
/// the text, and the sender is the record's, its name from the text only when the record has none (a
/// sender that only named itself).
function reading(raw: string, body: UserBody, context?: IncomingContext): IncomingPrompt | undefined {
  const proof = body.incoming;
  if (!proof) return incomingPrompt(raw, body.viaCli ? { client: `acpmux-cli#@${body.viaCli}` } : {}, context);
  if (proof.kind === "hidden") return { kind: "hidden" };
  if (proof.kind === "inbox") return incomingPrompt(raw, { _meta: { provenance: { kind: "inbox_notice" } } }, context);
  const read = incomingPrompt(raw, { _meta: { provenance: { kind: "agent_message", from: "fromAgent" } } }, context);
  const { unverified: _, ...message } = read?.kind === "message" ? read.message : { name: "", text: raw, raw };
  const sender = proof.sender ?? {};
  return {
    kind: "message",
    message: {
      ...message,
      ...(sender.name ? { name: sender.name } : {}),
      ...(sender.harness ? { harness: sender.harness } : {}),
      ...(sender.relay ? { lookup: sender.relay } : {}),
      ...(sender.unverified ? { unverified: true as const } : {}),
    },
  };
}

/// The row's text and how it reads: v1's `shown`, `untyped` and the fields its gate lets through.
export function userPrompt(body: UserBody, context?: IncomingContext): Partial<AcpmuxRow> {
  const raw = String(body.content ?? "");
  const incoming = reading(raw, body, context);
  const shown: Partial<AcpmuxRow> =
    incoming?.kind === "message"
      ? {
          text: incoming.message.notice
            ? noticeRowText(incoming.message.notice, incoming.message.text)
            : incoming.message.text,
          incoming,
          resend: raw,
        }
      : incoming?.kind === "notice"
        ? { text: incoming.text, incoming }
        : incoming?.kind === "inbox"
          ? { text: inboxText(incoming.notice), incoming }
          : incoming?.kind === "hidden"
            ? { text: "", incoming }
            : { text: incoming?.kind === "prompt" ? incoming.text : raw };
  const untyped = incoming !== undefined && incoming.kind !== "prompt";
  return {
    ...shown,
    ...(untyped ? { untyped } : {}),
    ...(!untyped && body.author ? { author: body.author } : {}),
    ...(!untyped && body.viaCli ? { viaCli: body.viaCli } : {}),
    ...((!untyped || incoming?.kind === "message") && body.sentFrom ? { sentFrom: body.sentFrom } : {}),
    ...(!untyped && body.agentText ? { agentText: body.agentText } : {}),
  };
}
