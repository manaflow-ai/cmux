// The agent pane's client of the shared page host (`cmux-page://cmux.agent/`): the one page client,
// and old `agentSession` method calls as `cmux.agent.*` calls. A leaf apart from pageHost.ts, whose
// host events reach every pane store, so a page that only posts to the host (native.ts's
// `postNative`) loads none of them.
import { createPageClient, isPageError, RECEIVE_NAME, type PageClient } from "../../pages/shared/pageClient";
import { installNativeMenu } from "../../ui/nativeMenu";
import { NativeError } from "./nativeError";

const RENAMED: Record<string, string> = {
  ready: "handshake",
  "chat.persistSession": "session.persist",
};

/// The `cmux.agent` op of an old bridge method.
export function agentPageOp(method: string): string {
  return `cmux.agent.${RENAMED[method] ?? method}`;
}

let client: PageClient | null = null;

/// The page host client when the page runs on the shared page host, else null (the old host).
export function pageHostClient(): PageClient | null {
  // Only a found client is kept: it owns the page's receive hook, so there is one per page.
  client ??= createPageClient();
  return client;
}

/// Tests: the page starts again with no page host client, as a new page does. A test that installs
/// a fake `cmuxPage` handler calls it in its teardown, so a later test file's requests do not go to
/// that fake through the kept client (its native menu and receive hook go with it).
export function resetPageHostClientForTests(): void {
  if (!client) return;
  client = null;
  installNativeMenu(null);
  delete (globalThis as Record<string, unknown>)[RECEIVE_NAME];
}

/// Calls `method` on the page host. Rejects with a `NativeError` as the old bridge did: the host's
/// code, message, retryable, and the `origin` and `details` the host put in the error's details. A
/// request the host refused before it reached the pane is origin `native`, with the protocol's own
/// code in `details.protocol` (`cmux.protocol.unknown_op`: this host has no such op); a lost link
/// leaves code and origin unset, because nothing tells whether the request ran.
export async function callPageHost<T>(
  page: PageClient,
  method: string,
  params: Record<string, unknown> = {},
): Promise<T> {
  try {
    return await page.call<T>(agentPageOp(method), params);
  } catch (error) {
    if (!isPageError(error)) throw new NativeError(undefined, String(error));
    if (error.code === "cmux.protocol.unknown_op" || error.code === "cmux.protocol.invalid_params")
      throw new NativeError({
        code: "native.invalid_request",
        origin: "native",
        userMessage: error.message,
        details: { protocol: error.code },
      });
    if (error.code.startsWith("cmux.protocol.")) throw new NativeError({ userMessage: error.message });
    const details = (error as { details?: { origin?: unknown; details?: unknown } }).details;
    throw new NativeError({
      code: error.code,
      userMessage: error.message,
      retryable: error.retryable,
      origin: details?.origin,
      details: details?.details,
    });
  }
}
