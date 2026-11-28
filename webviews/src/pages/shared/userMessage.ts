// What a failure says to the person: one plain, localized sentence chosen by the error's code,
// never the error's own text. An owner's `message` is written for logs (a Swift Debug string, a
// Rust error chain, a stack): it stays in the error for the log and any Details affordance, and
// the page shows the sentence its code maps to.

import { resolveLanguage } from "./i18n";
import table from "./generated/strings.json";

/** In a page's `sentences`: the owner's message for this code is already a localized sentence
 *  written for the person (a Swift `Strings` value), so the page shows it as is. */
export const OWNER_SENTENCE = true;

/** A page's own sentences by error code, or ``OWNER_SENTENCE`` for codes whose owner already
 *  sends a localized sentence. */
export type ErrorSentences = Readonly<Record<string, string | typeof OWNER_SENTENCE>>;

/** Codes every page means the same thing by: the link to cmux is down, this cmux lacks the op, or
 *  an agent (a harness profile) already has the name. */
const SHARED: Readonly<Record<string, string>> = {
  "cmux.protocol.closed": "error.disconnected",
  "cmux.protocol.unavailable": "error.disconnected",
  disconnected: "error.disconnected",
  unreachable: "error.disconnected",
  timeout: "error.disconnected",
  "cmux.protocol.unknown_op": "error.unsupported",
  "cmux.agents.exists": "error.agentExists",
};

let local: Record<string, string> | undefined;

function text(key: string): string {
  if (!local) {
    const nav = globalThis.navigator;
    const tags = nav?.languages?.length ? nav.languages : [nav?.language ?? "en"];
    local = (table as Record<string, Record<string, string>>)[resolveLanguage(tags, Object.keys(table))] ?? {};
  }
  return local[key] ?? (table as Record<string, Record<string, string>>).en[key] ?? key;
}

/** The sentence to show for `error`: the page's own sentence for its code, the owner's when the
 *  page marks that code ``OWNER_SENTENCE``, a shared sentence for a lost link or a missing op,
 *  else "Something went wrong. Try again." */
export function userMessage(error: unknown, sentences: ErrorSentences = {}): string {
  const code = typeof (error as { code?: unknown } | null)?.code === "string" ? (error as { code: string }).code : "";
  const own = code ? sentences[code] : undefined;
  if (typeof own === "string") return own;
  const said = (error as { message?: unknown } | null)?.message;
  if (own === OWNER_SENTENCE && typeof said === "string" && said) return said;
  return text(SHARED[code] ?? "error.generic");
}
