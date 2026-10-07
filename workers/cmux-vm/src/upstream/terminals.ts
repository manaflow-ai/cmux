/**
 * Provider terminal (PTY) operations. Every method demands proof that the
 * caller's tenant owns the VM and that the credential carries `vm:terminal`.
 * See upstream/PINNED.json for the pinned provider API surface.
 */
import type { Named } from "@gdp-ts/core";
import { Context, Effect, Schema } from "effect";
import type { VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { type UpstreamConfig, UpstreamError } from "./client.ts";
import { makeUpstreamHttp, proofSegment } from "./http.ts";

export const UpstreamPtySession = Schema.Struct({
  sessionId: Schema.Int,
  state: Schema.String,
  createdUnix: Schema.Number,
  cols: Schema.Int,
  rows: Schema.Int,
  exitCode: Schema.optional(Schema.NullOr(Schema.Int)),
  linuxUser: Schema.optional(Schema.NullOr(Schema.String)),
  slug: Schema.optional(Schema.NullOr(Schema.String)),
});
export type UpstreamPtySession = typeof UpstreamPtySession.Type;

const ListPtySessions = Schema.Struct({ sessions: Schema.Array(UpstreamPtySession) });
const ClosedPtySession = Schema.Struct({ sessionId: Schema.Int, exitCode: Schema.optional(Schema.NullOr(Schema.Int)) });
export type UpstreamClosedPtySession = typeof ClosedPtySession.Type;

export interface OpenPtyOptions {
  readonly command?: string | undefined;
  readonly cols?: number | undefined;
  readonly rows?: number | undefined;
  readonly user?: string | undefined;
  readonly name?: string | undefined;
  readonly restartOnExit?: boolean | undefined;
}

/** A session id (digits) or the name a session was opened with. */
export type TerminalSelector = string;

type TerminalProofs<C, V> = { readonly owns: TenantOwnsResource<C, V>; readonly scope: KeyHasScope<C, "vm:terminal"> };

export interface UpstreamTerminalsService {
  /** Opens a terminal and returns the provider's end of its WebSocket, not yet accepted. */
  readonly openTerminal: <C, V>(vm: Named<V, VmId>, proofs: TerminalProofs<C, V>, options: OpenPtyOptions) => Effect.Effect<WebSocket, UpstreamError>;
  readonly attachTerminal: <C, V>(
    vm: Named<V, VmId>,
    proofs: TerminalProofs<C, V>,
    session: TerminalSelector,
    user: string | undefined,
  ) => Effect.Effect<WebSocket, UpstreamError>;
  readonly listTerminals: <C, V>(
    vm: Named<V, VmId>,
    proofs: TerminalProofs<C, V>,
    user: string | undefined,
  ) => Effect.Effect<ReadonlyArray<UpstreamPtySession>, UpstreamError>;
  readonly closeTerminal: <C, V>(
    vm: Named<V, VmId>,
    proofs: TerminalProofs<C, V>,
    session: TerminalSelector,
    user: string | undefined,
  ) => Effect.Effect<UpstreamClosedPtySession, UpstreamError>;
  /** The provider id behind an owned VM, so the terminal bridge can scrub it from frames. Never sent to a client. */
  readonly scrubTarget: <C, V>(proofs: TerminalProofs<C, V>) => string;
}

export class UpstreamTerminals extends Context.Tag("cmux-vm/UpstreamTerminals")<UpstreamTerminals, UpstreamTerminalsService>() {}

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
    scrubTarget: ({ owns }) => decodeURIComponent(proofSegment(owns)),
  };
}
