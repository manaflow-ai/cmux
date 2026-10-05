// The agent pane on the shared page host (`cmux-page://cmux.agent/`, CmuxNextAgentPane
// AgentPageProvider): the old `agentSession` methods become `cmux.agent.*` pane-protocol calls, and
// the scripts the old host evaluated become events of the stream `cmux.agent.host.events`.
import { createPageClient, isPageError, type PageClient } from "../../pages/shared/pageClient";
import { NativeError } from "./nativeError";

export const HOST_EVENTS = "cmux.agent.host.events";
/// NewTabPage's FOCUS_LOCATION_EVENT, kept here so the transport does not load the new tab page.
export const FOCUS_LOCATION = "acpmux-focus-location";

const RENAMED: Record<string, string> = { ready: "handshake", "chat.persistSession": "session.persist" };

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

/// Calls `method` on the page host. Rejects with a `NativeError` as the old bridge did: the host's
/// code, message, retryable, and the `origin` and `details` the host put in the error's details. A
/// request the host refused before it reached the pane is origin `native`; a lost link leaves code
/// and origin unset, because nothing tells whether the request ran.
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
      throw new NativeError({ code: "native.invalid_request", origin: "native", userMessage: error.message });
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

export type HostEvent = { kind: string; value?: unknown };

/// Runs one host event in the page: the same `cmuxAcpmuxBridge` function the old host's script ran.
/// The user's registry.js is not an event: the host evaluates it, since the page's CSP
/// (script-src 'self') refuses a script element the page makes.
export function applyHostEvent(event: HostEvent): void {
  const bridge = window.cmuxAcpmuxBridge;
  const value = event.value as never;
  switch (event.kind) {
    case "theme": {
      const theme = event.value as { web?: unknown; agent?: Record<string, unknown> };
      (window as { cmuxTheme?: { apply(payload: unknown): void } }).cmuxTheme?.apply(theme.web);
      if (theme.agent) bridge?.applyTheme(theme.agent);
      return;
    }
    case "shortcuts":
      return bridge?.applyShortcuts?.(value);
    case "preview":
      return bridge?.applyPreview?.(event.value === true);
    case "customization":
      return bridge?.applyCustomization(value);
    case "dictation":
      return bridge?.dictation?.(value);
    case "revealTurn":
      return bridge?.revealTurn?.(String(event.value));
    case "command":
      return bridge?.command?.(String(event.value));
    case "focusLocation":
      window.dispatchEvent(new Event(FOCUS_LOCATION));
      return;
  }
}

const subscribed = new WeakSet<PageClient>();

/// Subscribes to host events once per client, after the page installed `cmuxAcpmuxBridge`.
export async function startHostEvents(page: PageClient): Promise<void> {
  if (subscribed.has(page)) return;
  subscribed.add(page);
  await page.subscribe<HostEvent>(HOST_EVENTS, (event) => applyHostEvent(event));
}
