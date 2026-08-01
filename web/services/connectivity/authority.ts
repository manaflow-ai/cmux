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
  readonly snapshot_complete?: true;
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
      const snapshot = yield* completeDiscoverySnapshot(broker, userId, now);
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
  };
}

function completeDiscoverySnapshot(
  broker: Pick<IrohTrustBrokerShape, "discover">,
  userId: string,
  now: Date,
): Effect.Effect<ConnectivityDiscoverySnapshot, IrohExpectedError> {
  return Effect.gen(function* () {
    const bindings: unknown[] = [];
    const bindingIds = new Set<string>();
    const seenCursors = new Set<string>();
    let cursor: string | undefined;
    let first: ConnectivityDiscoveryPage | undefined;

    do {
      const rawPage = yield* broker.discover(userId, now, {
        pageSize: "128",
        ...(cursor ? { cursor } : {}),
      });
      const page = yield* parseDiscoveryPage(rawPage);
      if (first) {
        const initialPage = first;
        yield* Effect.try({
          try: () => requireSameSnapshot(initialPage, page),
          catch: (cause) => new IrohDatabaseError({
            operation: "connectivity.sync.discovery",
            cause,
          }),
        });
      } else {
        first = page;
      }
      for (const binding of page.bindings) {
        const bindingId = yield* Effect.try({
          try: () => discoveryBindingId(binding),
          catch: (cause) => new IrohDatabaseError({
            operation: "connectivity.sync.discovery",
            cause,
          }),
        });
        if (bindingIds.has(bindingId)) {
          return yield* Effect.fail(new IrohDatabaseError({
            operation: "connectivity.sync.discovery",
            cause: new Error("duplicate discovery binding"),
          }));
        }
        bindingIds.add(bindingId);
        bindings.push(binding);
      }
      if (page.next_cursor !== null && seenCursors.has(page.next_cursor)) {
        return yield* Effect.fail(new IrohDatabaseError({
          operation: "connectivity.sync.discovery",
          cause: new Error("repeated discovery cursor"),
        }));
      }
      if (page.next_cursor !== null) seenCursors.add(page.next_cursor);
      cursor = page.next_cursor ?? undefined;
    } while (cursor);

    if (!first) {
      return yield* Effect.fail(new IrohDatabaseError({
        operation: "connectivity.sync.discovery",
        cause: new Error("missing discovery snapshot"),
      }));
    }
    const { next_cursor: _, ...snapshot } = first;
    return { ...snapshot, bindings };
  });
}

type ConnectivityDiscoveryPage = ConnectivityDiscoverySnapshot & {
  readonly bindings: readonly unknown[];
  readonly next_cursor: string | null;
};

function parseDiscoveryPage(
  value: unknown,
): Effect.Effect<ConnectivityDiscoveryPage, IrohDatabaseError> {
  return Effect.try({
    try: () => {
      const snapshot = discoverySnapshot(value);
      const page = snapshot as Record<string, unknown>;
      if (
        !Array.isArray(page.bindings)
        || (page.next_cursor !== null
          && (typeof page.next_cursor !== "string" || page.next_cursor.length === 0))
      ) {
        throw new Error("invalid internal discovery page");
      }
      return snapshot as ConnectivityDiscoveryPage;
    },
    catch: (cause) => new IrohDatabaseError({
      operation: "connectivity.sync.discovery",
      cause,
    }),
  });
}

function requireSameSnapshot(
  first: ConnectivityDiscoveryPage,
  page: ConnectivityDiscoveryPage,
): void {
  const metadataKeys = [
    "relay_fleet",
    "lan_rendezvous",
    "grant_verification_keys",
  ] as const;
  if (
    page.route_contract_version !== first.route_contract_version
    || page.revision !== first.revision
    || metadataKeys.some((key) => JSON.stringify(page[key]) !== JSON.stringify(first[key]))
  ) {
    throw new Error("discovery snapshot changed between pages");
  }
}

function discoveryBindingId(value: unknown): string {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid discovery binding");
  }
  const bindingId = (value as Record<string, unknown>).binding_id;
  if (typeof bindingId !== "string" || bindingId.length === 0) {
    throw new Error("invalid discovery binding");
  }
  return bindingId;
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
