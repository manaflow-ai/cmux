import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  IrohDatabaseError,
  type IrohExpectedError,
} from "../iroh/errors";
import {
  IrohTrustBroker,
  IrohTrustBrokerRuntime,
  type IrohTrustBrokerShape,
} from "../iroh/trustBroker";
import {
  CONNECTIVITY_PROTOCOL_VERSION,
  SCOPED_CONNECTIVITY_PROTOCOL_VERSION,
  parseConnectivitySyncRequest,
  parseScopedConnectivitySyncRequest,
} from "./model";
import { irohDiscoveryScopeJSON } from "../iroh/discoveryScope";

export type ConnectivityDiscoverySnapshot = Readonly<Record<string, unknown>> & {
  readonly route_contract_version: 1;
  readonly revision: number;
};

export type ConnectivitySyncResponse = {
  readonly protocol_version: typeof CONNECTIVITY_PROTOCOL_VERSION;
  readonly revision: number;
  readonly changed: boolean;
  readonly reset: boolean;
  readonly snapshot?: ConnectivityDiscoverySnapshot;
  readonly snapshot_complete?: true;
};

export type ScopedConnectivitySyncResponse = {
  readonly protocol_version: typeof SCOPED_CONNECTIVITY_PROTOCOL_VERSION;
  readonly revision: number;
  readonly changed: boolean;
  readonly reset: boolean;
  readonly discovery_scope: Readonly<Record<string, unknown>>;
  readonly snapshot?: ConnectivityDiscoverySnapshot;
  readonly snapshot_scope_complete?: true;
};

export type ConnectivityAuthorityShape = {
  readonly sync: (
    userId: string,
    raw: unknown,
    now?: Date,
  ) => Effect.Effect<ConnectivitySyncResponse, IrohExpectedError>;
  readonly syncScoped: (
    userId: string,
    raw: unknown,
    now?: Date,
  ) => Effect.Effect<ScopedConnectivitySyncResponse, IrohExpectedError>;
};

export class ConnectivityAuthority extends Context.Tag("cmux/ConnectivityAuthority")<
  ConnectivityAuthority,
  ConnectivityAuthorityShape
>() {}

export function makeConnectivityAuthority(
  broker: Pick<IrohTrustBrokerShape, "discoverComplete" | "discoverScoped">,
): ConnectivityAuthorityShape {
  return {
    sync: (userId, raw, now = new Date()) => Effect.gen(function* () {
      const request = yield* Effect.try({
        try: () => parseConnectivitySyncRequest(raw),
        catch: (error) => error as IrohExpectedError,
      });
      const snapshot = yield* parseDiscoverySnapshot(
        yield* broker.discoverComplete(userId, now),
      );
      const changed = request.known_revision !== snapshot.revision;
      return {
        protocol_version: CONNECTIVITY_PROTOCOL_VERSION,
        revision: snapshot.revision,
        changed,
        reset: request.known_revision !== null
          && request.known_revision > snapshot.revision,
        ...(changed ? { snapshot, snapshot_complete: true as const } : {}),
      };
    }),
    syncScoped: (userId, raw, now = new Date()) => Effect.gen(function* () {
      const request = yield* Effect.try({
        try: () => parseScopedConnectivitySyncRequest(raw),
        catch: (error) => error as IrohExpectedError,
      });
      const snapshot = yield* parseDiscoverySnapshot(
        yield* broker.discoverScoped(userId, request.discovery_scope, now),
      );
      const changed = request.known_revision !== snapshot.revision;
      return {
        protocol_version: SCOPED_CONNECTIVITY_PROTOCOL_VERSION,
        revision: snapshot.revision,
        changed,
        reset: request.known_revision !== null
          && request.known_revision > snapshot.revision,
        discovery_scope: irohDiscoveryScopeJSON(request.discovery_scope),
        ...(changed
          ? { snapshot, snapshot_scope_complete: true as const }
          : {}),
      };
    }),
  };
}

function parseDiscoverySnapshot(
  value: unknown,
): Effect.Effect<ConnectivityDiscoverySnapshot, IrohDatabaseError> {
  return Effect.try({
    try: () => {
      const snapshot = discoverySnapshot(value);
      if (!Array.isArray(snapshot.bindings)) {
        throw new Error("invalid internal discovery snapshot");
      }
      return snapshot;
    },
    catch: (cause) => new IrohDatabaseError({
      operation: "connectivity.sync.discovery",
      cause,
    }),
  });
}

function discoverySnapshot(value: unknown): ConnectivityDiscoverySnapshot {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid internal discovery snapshot");
  }
  const snapshot = value as Record<string, unknown>;
  if (
    snapshot.route_contract_version !== 1
    || !Number.isSafeInteger(snapshot.revision)
    || (snapshot.revision as number) < 0
  ) {
    throw new Error("invalid internal discovery snapshot");
  }
  return snapshot as ConnectivityDiscoverySnapshot;
}

export const ConnectivityAuthorityLive = Layer.effect(
  ConnectivityAuthority,
  Effect.gen(function* () {
    return makeConnectivityAuthority(yield* IrohTrustBroker);
  }),
);

export const ConnectivityAuthorityRuntime = ConnectivityAuthorityLive.pipe(
  Layer.provide(IrohTrustBrokerRuntime),
);
