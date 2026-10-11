/**
 * Provider terminal (PTY) operations, as handlers see them; the implementation
 * that holds the provider key is src/upstream/live-terminals.ts. Every method demands proof that the
 * caller's tenant owns the VM and that the credential carries `vm:terminal`.
 * See upstream/PINNED.json for the pinned provider API surface.
 */
import type { Named } from "@gdp-ts/core";
import { Context, Effect, Schema } from "effect";
import type { VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import type { UpstreamError } from "./client.ts";

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

export const ListPtySessions = Schema.Struct({ sessions: Schema.Array(UpstreamPtySession) });
export const ClosedPtySession = Schema.Struct({ sessionId: Schema.Int, exitCode: Schema.optional(Schema.NullOr(Schema.Int)) });
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
}

export class UpstreamTerminals extends Context.Tag("cmux-vm/UpstreamTerminals")<UpstreamTerminals, UpstreamTerminalsService>() {}

