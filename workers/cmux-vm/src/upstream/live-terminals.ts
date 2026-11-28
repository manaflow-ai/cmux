/**
 * The live provider terminal client (see src/upstream/terminals.ts for the
 * interface). Imported only from src/upstream/, src/proofs/ and src/index.ts.
 */
import { Effect, Layer, Redacted, Schema } from "effect";
import type { Environment } from "../policy.ts";
import { UpstreamError } from "./client.ts";
import { makeUpstreamHttp, proofSegment } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";
import { ClosedPtySession, ListPtySessions, UpstreamTerminals, type UpstreamTerminalsService } from "./terminals.ts";

const query = (entries: ReadonlyArray<readonly [string, string | number | boolean | undefined]>): string => {
  const params = new URLSearchParams();
  for (const [key, value] of entries) if (value !== undefined) params.set(key, String(value));
  const text = params.toString();
  return text.length === 0 ? "" : `?${text}`;
};

const decodeAs =
  <A, I>(schema: Schema.Schema<A, I>, operation: string) =>
  (body: unknown): Effect.Effect<A, UpstreamError> =>
    Schema.decodeUnknown(schema)(body).pipe(Effect.mapError(() => new UpstreamError({ operation, status: null })));

export function makeUpstreamTerminals(config: UpstreamConfig): UpstreamTerminalsService {
  const http = makeUpstreamHttp(config);
  return {
    openTerminal: (_vm, { owns }, options) =>
      http.upgrade(
        "openTerminal",
        `/v5/vms/${proofSegment(owns)}/pty${query([
          ["exec", options.command],
          ["cols", options.cols],
          ["rows", options.rows],
          ["linuxUser", options.user],
          ["slug", options.name],
          ["replaceOnExit", options.restartOnExit],
        ])}`,
      ),
    attachTerminal: (_vm, { owns }, session, user) =>
      http.upgrade(
        "attachTerminal",
        `/v5/vms/${proofSegment(owns)}/pty/sessions/${encodeURIComponent(session)}${query([["linuxUser", user]])}`,
      ),
    listTerminals: (_vm, { owns }, user) =>
      http
        .json("listTerminals", "GET", `/v5/vms/${proofSegment(owns)}/pty/sessions${query([["linuxUser", user]])}`)
        .pipe(
          Effect.flatMap(decodeAs(ListPtySessions, "listTerminals")),
          Effect.map((body) => body.sessions),
        ),
    closeTerminal: (_vm, { owns }, session, user) =>
      http
        .json(
          "closeTerminal",
          "DELETE",
          `/v5/vms/${proofSegment(owns)}/pty/sessions/${encodeURIComponent(session)}${query([["linuxUser", user]])}`,
        )
        .pipe(Effect.flatMap(decodeAs(ClosedPtySession, "closeTerminal"))),
  };
}

export const upstreamTerminalsLayer = (config: { readonly baseUrl: string; readonly apiKey: string; readonly environment: Environment }): Layer.Layer<UpstreamTerminals> =>
  Layer.succeed(UpstreamTerminals, makeUpstreamTerminals({ baseUrl: config.baseUrl, apiKey: Redacted.make(config.apiKey), environment: config.environment }));
