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

/// The host's answer to `method`, or its refusal: `code` is the host's error code (`link.*` for a
/// path it refused, `unsupported` for a method it doesn't know), undefined when the call never
/// reached it.
export type ChipHostAnswer = { ok: true; value: unknown } | { ok: false; code?: string };

/// Sends `method` and keeps a refusal apart from an answer, for a caller that must tell "no
/// preview" from "this host can't say".
export function askChipHost(method: string, params: Record<string, unknown>): Promise<ChipHostAnswer> {
  return Promise.resolve()
    .then(() => call(method, params))
    .then(
      (value): ChipHostAnswer => ({ ok: true, value }),
      (error: unknown): ChipHostAnswer => {
        const code = (error as { code?: unknown } | null)?.code;
        return { ok: false, code: typeof code === "string" ? code : undefined };
      },
    );
}

/// Tests replace the host.
export function setChipHost(next: Call | undefined): void {
  call = next ?? postNative;
}
