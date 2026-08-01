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
  parseConnectivitySyncRequest,
} from "./model";

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
};

export type ConnectivityAuthorityShape = {
  readonly sync: (
    userId: string,
    raw: unknown,
    now?: Date,
  ) => Effect.Effect<ConnectivitySyncResponse, IrohExpectedError>;
};

export class ConnectivityAuthority extends Context.Tag("cmux/ConnectivityAuthority")<
  ConnectivityAuthority,
  ConnectivityAuthorityShape
>() {}

export function makeConnectivityAuthority(
  broker: Pick<IrohTrustBrokerShape, "discover">,
): ConnectivityAuthorityShape {
  return {
    sync: (userId, raw, now = new Date()) => Effect.gen(function* () {
      const request = yield* Effect.try({
        try: () => parseConnectivitySyncRequest(raw),
        catch: (error) => error as IrohExpectedError,
      });
      const rawSnapshot = yield* broker.discover(userId, now);
      const snapshot = yield* Effect.try({
        try: () => discoverySnapshot(rawSnapshot),
        catch: (cause) => new IrohDatabaseError({
          operation: "connectivity.sync.discovery",
          cause,
        }),
      });
      const changed = request.known_revision !== snapshot.revision;
      return {
        protocol_version: CONNECTIVITY_PROTOCOL_VERSION,
        revision: snapshot.revision,
        changed,
        reset: request.known_revision !== null
          && request.known_revision > snapshot.revision,
        ...(changed ? { snapshot } : {}),
      };
    }),
  };
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
