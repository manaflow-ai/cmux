// A page newer than the app's relay (a web update served ahead of the nightly that carries the relay's
// side) sends a key the relay's params rule does not know, and an older relay refuses the whole request
// as `transport.intent_invalid` with `detail: unknown param "<key>"`. NIGHTLY a3a24c8 refused every
// chat's open that way once #52780's page (`_acpmux/attach` `attending`) reached it: "cmux blocked
// opening this chat" over a blank chat (cmux#55066). A relay from #49717 on drops such keys itself; the
// page does the same for an older one: it sends the request once more without the key it named, as
// the newer relay would have. Only a top-level key the request carries, never one of a mode field's
// or a gesture's own refusals, which name no unknown param.

const UNKNOWN_PARAM = /^unknown param "([^"]{1,64})"$/;

/// Keys that name what the request asks, never dropped: the same request without one is another
/// request, whose answer its caller would read as the one it asked. An attach without `hold` is a
/// plain page, which the row store would take for its hold and discard (cmux#44792 F1); its refusal
/// reaches the caller, which falls to v1 (`holdAttachRefused`).
const MEANING_KEYS: ReadonlySet<string> = new Set(["sessionId", "hold"]);

/// The top-level key of `params` an older relay refused as unknown in `error`, or undefined.
export function unknownParamRefused(error: unknown, params: Record<string, unknown>): string | undefined {
  const failure = error as { code?: unknown; detail?: unknown } | undefined;
  if (failure?.code !== "transport.intent_invalid" || typeof failure.detail !== "string") return undefined;
  const key = UNKNOWN_PARAM.exec(failure.detail.trim())?.[1];
  return key !== undefined && !MEANING_KEYS.has(key) && Object.hasOwn(params, key) ? key : undefined;
}

/// `params` without `key`.
export function withoutParam(params: Record<string, unknown>, key: string): Record<string, unknown> {
  const { [key]: _dropped, ...rest } = params;
  return rest;
}
