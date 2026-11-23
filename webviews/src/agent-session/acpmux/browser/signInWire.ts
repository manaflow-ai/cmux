// The browser's sign-in before the pane connects (cmux-stack-auth BrowserSignIn.md, "Listener
// adapter"). It runs on a socket of its own: the daemon keeps one pending sign-in per connection
// and drops it when that socket closes, and the pane's client must open with the enrollment
// already set (browserDevice.ts). Nothing here is stored: the access token goes straight to
// `setBrowserDeviceEnrollment`, in page memory.
import { tokenProtocols } from "../direct/hostConfig";

/** A refusal with the daemon's `data.reason` (`signin.unconfigured`, `browser.sign_in.*`). */
export type SignInError = Error & { reason: string };

export function signInError(reason: string, message = reason): SignInError {
  return Object.assign(new Error(message), { reason });
}

/** What the pane calls; the gallery and tests pass their own. */
export type SignInTransport = {
  start(email: string): Promise<{ expiresIn: number }>;
  complete(code: string): Promise<{ accessToken: string; publicKey: string }>;
  close(): void;
};

/** Every request has the same 30 s bound as the device handshake. */
const REQUEST_MS = 30_000;

/** A 32-byte public key in standard base64: the device's WireGuard (X25519) key, which the hub
 * names the device by. The private half is never needed by the page, so it is not kept. */
export async function devicePublicKey(): Promise<string> {
  let raw: Uint8Array;
  try {
    const pair = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
    raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  } catch {
    // A browser without X25519 in WebCrypto: a random clamped scalar's bytes stand in. The hub
    // checks only its length; this device never runs WireGuard.
    raw = crypto.getRandomValues(new Uint8Array(32));
  }
  let text = "";
  for (const byte of raw) text += String.fromCharCode(byte);
  return btoa(text);
}

/** A JSON-RPC socket for `_acpmux/browser_sign_in_start` and `_complete`, opened on first use. */
export function socketSignIn(endpoint: string, token: string, publicKey: () => Promise<string>): SignInTransport {
  let socket: Promise<WebSocket> | undefined;
  let key: string | undefined;
  let next = 1;
  const pending = new Map<number, { resolve(v: any): void; reject(e: unknown): void }>();
  const failAll = (error: unknown) => {
    for (const entry of pending.values()) entry.reject(error);
    pending.clear();
  };
  const open = () =>
    (socket ??= new Promise<WebSocket>((resolve, reject) => {
      const ws = new WebSocket(endpoint, tokenProtocols(token));
      ws.onopen = () => resolve(ws);
      ws.onerror = () => reject(signInError("signin.unreachable"));
      ws.onclose = () => {
        socket = undefined;
        failAll(signInError("signin.unreachable"));
      };
      ws.onmessage = (event) => {
        let message: any;
        try {
          message = JSON.parse(String(event.data));
        } catch {
          return;
        }
        const entry = typeof message?.id === "number" ? pending.get(message.id) : undefined;
        if (!entry) return;
        pending.delete(message.id);
        if (message.error) {
          const reason = message.error.data?.reason;
          entry.reject(
            signInError(typeof reason === "string" ? reason : "signin.refused", String(message.error.message)),
          );
        } else entry.resolve(message.result);
      };
    }));
  const request = async (method: string, params: Record<string, unknown>) => {
    const ws = await open();
    const id = next++;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await new Promise<any>((resolve, reject) => {
        pending.set(id, { resolve, reject });
        timer = setTimeout(() => {
          pending.delete(id);
          reject(signInError("signin.timeout"));
        }, REQUEST_MS);
        ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
      });
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  };
  return {
    async start(email) {
      key = await publicKey();
      const result = await request("_acpmux/browser_sign_in_start", { email, publicKey: key });
      return { expiresIn: typeof result?.expiresIn === "number" ? result.expiresIn : 300 };
    },
    async complete(code) {
      const result = await request("_acpmux/browser_sign_in_complete", { code });
      if (typeof result?.accessToken !== "string" || typeof result?.publicKey !== "string")
        throw signInError("signin.refused");
      return { accessToken: result.accessToken, publicKey: result.publicKey };
    },
    close() {
      failAll(signInError("signin.closed"));
      void socket?.then((ws) => ws.close()).catch(() => undefined);
      socket = undefined;
    },
  };
}
