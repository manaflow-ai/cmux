import { TeamStore, type TeamScope } from "../src/storage/team-store";
import { UserUsageStore } from "../src/storage/user-usage";
import { UserSocketStore } from "../src/storage/socket-store";
import { applyStorageMigrations } from "../src/storage/migrations";
import { drizzle } from "drizzle-orm/durable-sqlite";
import { sql } from "drizzle-orm";

const scope: TeamScope = { environment: "test", projectId: "iroh-v2-test", teamId: "team-e2e" };

/** Small real-workerd harness for storage tests. Production adapters call the same stores directly. */
export class StorageTestDO {
  readonly team: TeamStore;
  readonly usage: UserUsageStore;
  readonly sockets: UserSocketStore;
  constructor(ctx: DurableObjectState, env: unknown) {
    this.team = new TeamStore(ctx.storage, scope, { initialize: false });
    this.usage = new UserUsageStore(ctx.storage, { environment: scope.environment, projectId: scope.projectId }, { initialize: false });
    this.sockets = new UserSocketStore(ctx.storage, { environment: scope.environment, projectId: scope.projectId }, { initialize: false });
    ctx.blockConcurrencyWhile(async () => this.team.initialize());
  }

  async fetch(request: Request): Promise<Response> {
    try {
      const body = request.method === "POST" ? await request.json() as Record<string, any> : {};
      const path = new URL(request.url).pathname;
      if (path === "/issue") return Response.json(this.team.issueChallenge(body.identity, body.issue));
      if (path === "/fill-challenges") {
        // The expiry test leaves one pending slot. Fill the remaining slots with
        // distinct identities, then the test can verify replacement at capacity.
        for (let index = 0; index < 4095; index += 1) {
          const fillIdentity = {
            ...scope,
            userId: `fill-user-${index}`,
            deviceId: `fill-device-${index}`,
            appNamespace: "cmux",
            buildTag: "fill",
          };
          this.team.issueChallenge(fillIdentity, {
            challengeId: `fill-${index}`,
            nonceHash: `fill-nonce-${index}`,
            payloadHash: `fill-payload-${index}`,
            issuedAt: 7000 + index,
            expiresAt: 10000 + index,
          });
        }
        return Response.json({ ok: true });
      }
      if (path === "/validate") { this.team.validateRegistrationChallenge(body.input); return Response.json({ ok: true }); }
      if (path === "/register") return Response.json(this.team.commitRegistration(body.input));
      if (path === "/receipt") return Response.json(this.team.findRegistrationReceipt(body.identity, body.requestId, body.requestHash));
      if (path === "/proof") { this.team.consumeDeviceProof(body.input); return Response.json({ ok: true }); }
      if (path === "/revoke") { return Response.json({ revision: this.team.revokeDevice(body.deviceRecordId, body.now, body.actorUserId) }); }
      if (path === "/usage") return Response.json(this.usage.consume(body.userId, body.operation, body.nowMs));
      if (path === "/socket/reserve") { this.sockets.reserveSocket(body.input); return Response.json({ ok: true }); }
      if (path === "/socket/output") { this.sockets.setOutput(body.userId, body.sessionId, body.revision, body.bytes, body.messages); return Response.json({ ok: true }); }
      if (path === "/socket/release") { this.sockets.releaseSocket(body.userId, body.sessionId); return Response.json({ ok: true }); }
      if (path === "/socket/list") return Response.json(this.sockets.listSocketReservations(body.userId));
      if (path === "/revision") return Response.json({ revision: this.team.readRevision() });
      if (path === "/authority/observe") return Response.json({ revision: this.team.observeAuthority(body.userId, body.verifiedAt, body.expiresAt, body.now) });
      if (path === "/authority/get") return Response.json(this.team.getAuthority(body.userId));
      return new Response("not found", { status: 404 });
    } catch (error) {
      const code = error instanceof Error ? error.message : "unknown";
      return Response.json({ code }, { status: 500 });
    }
  }
}

/** Isolated migration probe used only to exercise the runtime migration transaction. */
export class MigrationProbeDO {
  constructor(private readonly ctx: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const body = request.method === "POST" ? await request.json() as Record<string, any> : {};
    const db = drizzle(this.ctx.storage);
    try {
      switch (new URL(request.url).pathname) {
        case "/seed":
          applyStorageMigrations(this.ctx.storage, 1);
          return Response.json({ ok: true });
        case "/corrupt": {
          const mode = body.mode;
          if (mode === "gap") db.run(sql`DELETE FROM "schema_history" WHERE "version" = 3`);
          else if (mode === "future") db.run(sql`INSERT INTO "schema_history" ("version", "hash", "applied_at") VALUES (99, 'future', 1)`);
          else if (mode === "wrong-hash") db.run(sql`UPDATE "schema_history" SET "hash" = 'wrong' WHERE "version" = 1`);
          else if (mode === "failed-upgrade") {
            db.run(sql`DELETE FROM "schema_history" WHERE "version" = 5`);
            db.run(sql.raw(`DROP TABLE IF EXISTS "user_authority"`));
            db.run(sql.raw(`CREATE VIEW "user_authority" AS SELECT 1 AS "user_id", 1 AS "verified_at", 1 AS "expires_at"`));
          } else throw new Error("unknown corruption mode");
          return Response.json({ ok: true });
        }
        case "/migrate":
          applyStorageMigrations(this.ctx.storage, 2);
          return Response.json({ ok: true });
        case "/inspect": {
          const history = db.all(sql`SELECT "version", "hash" FROM "schema_history" ORDER BY "version"`);
          const objects = db.all(sql`SELECT "name", "type" FROM "sqlite_master" WHERE "name" = 'user_authority'`);
          return Response.json({ history, objects });
        }
        default: return new Response("not found", { status: 404 });
      }
    } catch (error) {
      return Response.json({ code: error instanceof Error ? error.message : "unknown" }, { status: 500 });
    }
  }
}

export default { fetch: () => new Response("storage test harness") };
