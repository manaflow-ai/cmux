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

/// The user row body's fields the reading takes (FIELDS.md, AcpmuxRow).
export type UserBody = {
  content?: string;
  incoming?: IncomingPrompt;
  viaCli?: string;
  author?: AcpmuxRow["author"];
  sentFrom?: AcpmuxRow["sentFrom"];
  agentText?: AcpmuxRow["agentText"];
};

/// The row's text and how it reads: v1's `shown`, `untyped` and the fields its gate lets through.
export function userPrompt(body: UserBody, context?: IncomingContext): Partial<AcpmuxRow> {
  const raw = String(body.content ?? "");
  // What the record proved wins; otherwise the text is read as v1 reads it. A row's `viaCli` is the
  // host of the CLI that sent it (`cliHost`), which is what the reading asks of the record.
  const incoming =
    body.incoming ?? incomingPrompt(raw, body.viaCli ? { client: `acpmux-cli#@${body.viaCli}` } : {}, context);
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
