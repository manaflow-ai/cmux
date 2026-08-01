import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  IrohConflictError,
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

const CONNECTIVITY_DISCOVERY_PAGE_SIZE = 128;
const CONNECTIVITY_DISCOVERY_ATTEMPT_LIMIT = 4;

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
        ...(changed ? { snapshot } : {}),
      };
    }),
  };
}

function completeDiscoverySnapshot(
  broker: Pick<IrohTrustBrokerShape, "discover">,
  userId: string,
  now: Date,
  attemptsRemaining = CONNECTIVITY_DISCOVERY_ATTEMPT_LIMIT,
): Effect.Effect<ConnectivityDiscoverySnapshot, IrohExpectedError> {
  return discoverSnapshotAttempt(broker, userId, now).pipe(
    Effect.catchAll((error) => {
      if (isDiscoveryChurn(error) && attemptsRemaining > 1) {
        return completeDiscoverySnapshot(
          broker,
          userId,
          now,
          attemptsRemaining - 1,
        );
      }
      return Effect.fail(error);
    }),
  );
}

function discoverSnapshotAttempt(
  broker: Pick<IrohTrustBrokerShape, "discover">,
  userId: string,
  now: Date,
): Effect.Effect<ConnectivityDiscoverySnapshot, IrohExpectedError> {
  return Effect.gen(function* () {
    let cursor: string | undefined;
    let firstMetadata: Record<string, unknown> | undefined;
    let firstFingerprint: string | undefined;
    const bindings: unknown[] = [];
    const seenCursors = new Set<string>();

    do {
      const rawPage = yield* broker.discover(userId, now, {
        pageSize: String(CONNECTIVITY_DISCOVERY_PAGE_SIZE),
        ...(cursor ? { cursor } : {}),
      });
      const page = yield* Effect.try({
        try: () => discoveryPage(rawPage),
        catch: (cause) => new IrohDatabaseError({
          operation: "connectivity.sync.discovery",
          cause,
        }),
      });
      if (firstFingerprint === undefined) {
        firstMetadata = page.metadata;
        firstFingerprint = page.fingerprint;
      } else if (page.fingerprint !== firstFingerprint) {
        return yield* Effect.fail(new IrohConflictError({
          code: "discovery_snapshot_changed",
        }));
      }
      bindings.push(...page.bindings);
      if (page.nextCursor && seenCursors.has(page.nextCursor)) {
        return yield* Effect.fail(new IrohDatabaseError({
          operation: "connectivity.sync.discovery",
          cause: new Error("connectivity discovery cursor loop"),
        }));
      }
      if (page.nextCursor) seenCursors.add(page.nextCursor);
      cursor = page.nextCursor ?? undefined;
    } while (cursor);

    if (!firstMetadata) {
      return yield* Effect.fail(new IrohDatabaseError({
        operation: "connectivity.sync.discovery",
        cause: new Error("empty connectivity discovery"),
      }));
    }
    return discoverySnapshot({ ...firstMetadata, bindings });
  });
}

function discoveryPage(value: unknown): {
  readonly metadata: Record<string, unknown>;
  readonly fingerprint: string;
  readonly bindings: unknown[];
  readonly nextCursor: string | null;
} {
  const snapshot = discoverySnapshot(value);
  const record = snapshot as Record<string, unknown>;
  const bindings = record.bindings;
  const nextCursor = record.next_cursor ?? null;
  if (
    !Array.isArray(bindings)
    || (nextCursor !== null && typeof nextCursor !== "string")
  ) {
    throw new Error("invalid internal discovery page");
  }
  const {
    bindings: _bindings,
    next_cursor: _nextCursor,
    ...metadata
  } = record;
  return {
    metadata,
    fingerprint: JSON.stringify(metadata),
    bindings,
    nextCursor,
  };
}

function isDiscoveryChurn(error: IrohExpectedError): boolean {
  return error._tag === "IrohConflictError"
    && (
      error.code === "discovery_cursor_stale"
      || error.code === "discovery_snapshot_changed"
    );
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
