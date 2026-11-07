// The chips' one way to the host: `postNative`, or a test's stand-in.
import { postNative } from "../native";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let call: Call = postNative;

/// Sends `method` to the host. A refusal (outside the roots, no gesture) changes nothing on
/// screen: the host's answer is the boundary, not the page's.
export function callChipHost(method: string, params: Record<string, unknown>): Promise<unknown> {
  // Outside the app (server render, a test without a host) the call itself can throw.
  return Promise.resolve()
    .then(() => call(method, params))
    .catch(() => undefined);
}

/// Sends `method` to the host: true when it did it, false when it refused (or there is no host).
export function tryChipHost(method: string, params: Record<string, unknown>): Promise<boolean> {
  return Promise.resolve()
    .then(() => call(method, params))
    .then(
      (reply) => !(reply && typeof reply === "object" && (reply as { ok?: unknown }).ok === false),
      () => false,
    );
}

/// Tests replace the host.
export function setChipHost(next: Call | undefined): void {
  call = next ?? postNative;
}
