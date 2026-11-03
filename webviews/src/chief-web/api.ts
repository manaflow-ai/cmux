import { ExpiredSession, type ChiefIdentity } from "./wire";

/** Same-origin session cookie; short-lived wire tickets never enter a URL or storage. */
export interface ChiefApi {
  me(signal: AbortSignal): Promise<ChiefIdentity>;
  ticket(signal: AbortSignal): Promise<string>;
  send(text: string, clientId: string, signal: AbortSignal): Promise<void>;
}

export class SendRefused extends Error {}

async function request(path: string, signal: AbortSignal, body?: object): Promise<Record<string, any>> {
  const response = await fetch(path, {
    method: body ? "POST" : "GET",
    credentials: "same-origin",
    signal: AbortSignal.any([signal, AbortSignal.timeout(30_000)]),
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status === 401 || response.status === 403) throw new ExpiredSession();
  if (!response.ok) {
    if (response.status >= 400 && response.status < 500 && response.status !== 408 && response.status !== 429)
      throw new SendRefused();
    throw new Error("unavailable");
  }
  return response.status === 204 ? {} : response.json();
}

export const chiefApi: ChiefApi = {
  async me(signal) {
    const raw = await request("/v1/chief/me", signal);
    return {
      handle: raw.handle,
      conversationId: raw.conversation,
      userId: raw.user,
      wireUrl: raw.wire_url,
    };
  },
  async ticket(signal) {
    const raw = await request("/v1/chief/ticket", signal, {});
    return raw.ticket;
  },
  async send(text, clientId, signal) {
    await request("/v1/chief/messages", signal, { text, client_msg_id: clientId });
  },
};
