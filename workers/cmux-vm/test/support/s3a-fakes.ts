/**
 * Fakes for the snapshot and terminal slice (S3a): in-memory snapshot store,
 * audit log, idempotency store and entitlements, plus the fake provider routes
 * fake-upstream.ts (S2) does not serve: reading a snapshot and terminals.
 * Creating and deleting snapshots go to fake-upstream.ts, which owns the
 * provider's snapshot map. The terminal
 * routes answer a WebSocket upgrade with one end of a Workers WebSocketPair
 * and hand the other end to a test-supplied script.
 */
import { Effect, Layer, Option, Redacted } from "effect";
import { AuditLog, type AuditEntry } from "../../src/db/audit.ts";
import { IdempotencyStore } from "../../src/db/idempotency.ts";
import { SnapshotStore, type SnapshotRow } from "../../src/db/snapshots.ts";
import { StoreError } from "../../src/db/sql.ts";
import type { OwnedResource } from "../../src/db/stores.ts";
import { newSnapshotId, SnapshotId, TenantId, UpstreamId, type VmId } from "../../src/lib/ids.ts";
import { Entitlements } from "../../src/proofs/tenant-may-create.ts";
import { makeUpstreamSnapshots } from "../../src/upstream/live-snapshots.ts";
import { makeUpstreamTerminals } from "../../src/upstream/live-terminals.ts";
import { UpstreamSnapshots } from "../../src/upstream/snapshots.ts";
import { UpstreamTerminals } from "../../src/upstream/terminals.ts";
import type { FakeUpstream } from "./fake-upstream.ts";

const UPSTREAM_URL = "https://upstream.test";
const UPSTREAM_KEY = "upstream-test-key";

interface SnapshotMeta {
  readonly sourceVmId: VmId | null;
  readonly displayName: string | null;
  readonly labels: Readonly<Record<string, string>>;
}

/** Runs against the provider's end of a terminal socket once the fake accepted it. */
export type TerminalScript = (socket: WebSocket, url: URL) => void;

export interface FakePtySession {
  readonly sessionId: number;
  readonly state: string;
  readonly slug: string | null;
  readonly linuxUser: string | null;
}

export function makeS3aFakes(resources: OwnedResource[], provider: FakeUpstream) {
  const meta = new Map<string, SnapshotMeta>();
  const auditLog: AuditEntry[] = [];
  const idempotency = new Map<string, { fingerprint: string; body: string | null }>();
  const deniedTenants = new Set<string>();
  /** Raw requests this fake served (terminal and snapshot reads), for header checks. */
  const requests: Request[] = [];
  const ptySessions = new Map<string, FakePtySession[]>();
  const state: { terminalScript: TerminalScript | null; failSnapshotRecord: boolean } = { terminalScript: null, failSnapshotRecord: false };

  const ownedSnapshot = (tenantId: string, id: string) =>
    resources.find((row) => row.tenantId === tenantId && row.kind === "snapshot" && row.cmuxId === id);

  const rowOf = (resource: OwnedResource): SnapshotRow => {
    const info = meta.get(resource.cmuxId);
    return {
      id: SnapshotId.make(resource.cmuxId),
      sourceVmId: info?.sourceVmId ?? null,
      displayName: info?.displayName ?? null,
      labels: info?.labels ?? {},
      createdAt: resource.createdAt,
    };
  };

  const snapshotStore = Layer.succeed(SnapshotStore, {
    record: (snapshot) =>
      Effect.suspend(() => {
        if (!state.failSnapshotRecord) return Effect.void;
        state.failSnapshotRecord = false;
        return Effect.fail(new StoreError({ operation: "snapshots.record", cause: "injected" }));
      }).pipe(
        Effect.zipRight(
          Effect.sync(() => {
            resources.push({
              tenantId: snapshot.tenantId,
              kind: "snapshot",
              cmuxId: snapshot.id,
              upstreamId: snapshot.upstreamId,
              createdBy: snapshot.createdBy,
              createdAt: snapshot.createdAt,
            });
            meta.set(snapshot.id, { sourceVmId: snapshot.sourceVmId, displayName: snapshot.displayName, labels: snapshot.labels });
          }),
        ),
      ),
    describe: (tenantId, id) =>
      Effect.sync(() => {
        const found = ownedSnapshot(tenantId, id);
        return found === undefined ? Option.none() : Option.some(rowOf(found));
      }),
    list: (tenantId, page) =>
      Effect.sync(() =>
        resources
          .filter((row) => row.tenantId === tenantId && row.kind === "snapshot")
          .map(rowOf)
          .filter((row) => page.sourceVmId === null || row.sourceVmId === page.sourceVmId)
          .filter((row) => Object.entries(page.labels ?? {}).every(([key, value]) => row.labels[key] === value))
          .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime() || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0))
          .filter(
            (row) =>
              page.after === null ||
              row.createdAt.getTime() < page.after.createdAt.getTime() ||
              (row.createdAt.getTime() === page.after.createdAt.getTime() && row.id < page.after.id),
          )
          .slice(0, page.limit),
      ),
    markDeleted: (tenantId, id) =>
      Effect.sync(() => {
        const index = resources.findIndex((row) => row.tenantId === tenantId && row.kind === "snapshot" && row.cmuxId === id);
        if (index >= 0) resources.splice(index, 1);
      }),
  });

  const auditLayer = Layer.succeed(AuditLog, { record: (entry) => Effect.sync(() => void auditLog.push(entry)) });

  const idempotencyLayer = Layer.succeed(IdempotencyStore, {
    claim: (tenantId, key, fingerprint) =>
      Effect.sync(() => {
        const slot = `${tenantId}\n${key}`;
        const existing = idempotency.get(slot);
        if (existing === undefined) {
          idempotency.set(slot, { fingerprint, body: null });
          return { _tag: "Started" } as const;
        }
        if (existing.fingerprint !== fingerprint) return { _tag: "Mismatch" } as const;
        return existing.body === null ? ({ _tag: "InProgress" } as const) : ({ _tag: "Replay", body: existing.body } as const);
      }),
    complete: (tenantId, key, fingerprint, body) =>
      Effect.sync(() => {
        const slot = `${tenantId}\n${key}`;
        if (idempotency.get(slot)?.fingerprint === fingerprint) idempotency.set(slot, { fingerprint, body });
      }),
    release: (tenantId, key, fingerprint) =>
      Effect.sync(() => {
        const slot = `${tenantId}\n${key}`;
        const existing = idempotency.get(slot);
        if (existing?.fingerprint === fingerprint && existing.body === null) idempotency.delete(slot);
      }),
  });

  const entitlementsLayer = Layer.succeed(Entitlements, {
    mayCreate: (tenantId) => Effect.sync(() => !deniedTenants.has(tenantId)),
  });

  const snapshotJson = (snapshot: { readonly id: string; readonly sourceVmId: string; readonly autoDeleteSeconds: number | null }) => ({
    id: snapshot.id,
    sourceVmId: snapshot.sourceVmId,
    slug: `slug-${snapshot.id}`,
    displayName: `cmux internal ${snapshot.id}`,
    accountId: "acct-leak-check",
    public: false,
    ttlSeconds: null,
    autoDeleteSeconds: snapshot.autoDeleteSeconds,
    lastUsedAt: null,
    createdAt: "2026-10-03T00:00:00Z",
    updatedAt: "2026-10-03T00:00:00Z",
  });

  const acceptTerminal = (url: URL): Response => {
    const pair = new WebSocketPair();
    const providerEnd = pair[1];
    providerEnd.accept();
    state.terminalScript?.(providerEnd, url);
    return new Response(null, { status: 101, webSocket: pair[0] });
  };

  /** Fake provider routes for reading a snapshot and for terminals; null for any other route. */
  const upstream = async (request: Request): Promise<Response | null> => {
    const url = new URL(request.url);
    const path = url.pathname;
    const oneSnapshot = /^\/v5\/snapshots\/([^/]+)$/.exec(path);
    const isSnapshotRead = oneSnapshot !== null && request.method === "GET";
    const isPty = /^\/v5\/vms\/[^/]+\/pty(\/.*)?$/.test(path);
    if (!isSnapshotRead && !isPty) return null;
    requests.push(request);
    provider.calls.push({ method: request.method, path, search: url.searchParams, json: null, bytes: null });
    if (request.headers.get("authorization") !== `Bearer ${UPSTREAM_KEY}`) {
      return Response.json({ code: "UNAUTHORIZED", message: "bad key" }, { status: 401 });
    }
    if (oneSnapshot?.[1] !== undefined) {
      const id = decodeURIComponent(oneSnapshot[1]);
      const snapshot = provider.snapshots.get(id);
      if (snapshot === undefined) return Response.json({ code: "NOT_FOUND", message: `snapshot ${id} not found` }, { status: 404 });
      return Response.json(snapshotJson(snapshot));
    }
    const pty = /^\/v5\/vms\/([^/]+)\/pty(?:\/sessions(?:\/([^/]+))?)?$/.exec(path);
    if (pty?.[1] !== undefined) {
      const vmId = decodeURIComponent(pty[1]);
      const isSessionsRoute = path.includes("/pty/sessions");
      const sessionSelector = pty[2] === undefined ? undefined : decodeURIComponent(pty[2]);
      const upgrade = request.headers.get("upgrade")?.toLowerCase() === "websocket";
      if (!isSessionsRoute) {
        if (!upgrade) return Response.json({ code: "BAD_REQUEST", message: "not a websocket" }, { status: 400 });
        return acceptTerminal(url);
      }
      const sessions = ptySessions.get(vmId) ?? [];
      if (sessionSelector === undefined) {
        return Response.json({
          sessions: sessions.map((session) => ({
            sessionId: session.sessionId,
            state: session.state,
            createdUnix: 1_790_000_000,
            cols: 80,
            rows: 24,
            exitCode: session.state === "exited" ? 0 : null,
            linuxUser: session.linuxUser,
            slug: session.slug,
          })),
        });
      }
      const session = sessions.find((candidate) => String(candidate.sessionId) === sessionSelector || candidate.slug === sessionSelector);
      if (session === undefined) {
        return Response.json({ code: "NOT_FOUND", message: `no session ${sessionSelector} on ${vmId}` }, { status: 404 });
      }
      if (upgrade && request.method === "GET") return acceptTerminal(url);
      if (request.method === "DELETE") {
        ptySessions.set(
          vmId,
          sessions.filter((candidate) => candidate !== session),
        );
        return Response.json({ sessionId: session.sessionId, exitCode: session.state === "exited" ? 0 : null });
      }
    }
    return Response.json({ code: "NOT_FOUND", message: "no such route" }, { status: 404 });
  };

  const layer = (fetch: (request: Request) => Promise<Response>) => {
    const config = { baseUrl: UPSTREAM_URL, apiKey: Redacted.make(UPSTREAM_KEY), fetch };
    return Layer.mergeAll(
      snapshotStore,
      auditLayer,
      idempotencyLayer,
      entitlementsLayer,
      Layer.succeed(UpstreamSnapshots, makeUpstreamSnapshots(config)),
      Layer.succeed(UpstreamTerminals, makeUpstreamTerminals(config)),
    );
  };

  return {
    upstream,
    layer,
    auditLog,
    requests,
    /** Records a snapshot owned by `tenant` and backed by a fake upstream snapshot. */
    addSnapshot(
      tenant: string,
      options: {
        readonly sourceVmId?: VmId;
        readonly displayName?: string;
        readonly labels?: Record<string, string>;
        readonly createdAt?: Date;
      } = {},
    ): { readonly snapshotId: SnapshotId; readonly upstreamId: string } {
      const snapshotId = newSnapshotId();
      const created = provider.addSnapshot(provider.addVm("running").id);
      const upstreamId = created.id;
      provider.snapshots.set(upstreamId, { ...created, autoDeleteSeconds: 3600 });
      resources.push({
        tenantId: TenantId.make(tenant),
        kind: "snapshot",
        cmuxId: snapshotId,
        upstreamId: UpstreamId.make(upstreamId),
        createdBy: "user:test",
        createdAt: options.createdAt ?? new Date(),
      });
      meta.set(snapshotId, {
        sourceVmId: options.sourceVmId ?? null,
        displayName: options.displayName ?? null,
        labels: options.labels ?? {},
      });
      return { snapshotId, upstreamId };
    },
    snapshotRows(tenant: string): ReadonlyArray<OwnedResource> {
      return resources.filter((row) => row.tenantId === tenant && row.kind === "snapshot");
    },
    denySnapshots(tenant: string) {
      deniedTenants.add(tenant);
    },
    failNextSnapshotRecord() {
      state.failSnapshotRecord = true;
    },
    onTerminal(script: TerminalScript) {
      state.terminalScript = script;
    },
    setPtySessions(upstreamVmId: string, sessions: ReadonlyArray<FakePtySession>) {
      ptySessions.set(upstreamVmId, [...sessions]);
    },
  };
}
