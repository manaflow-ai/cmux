// Test-only entrypoint. Production never imports this module.
import { DurableObject } from "cloudflare:workers";
import { accountDrizzleDatabase } from "../src/accountDrizzleDatabase";
import { migrate } from "drizzle-orm/durable-sqlite/migrator";
import { accountDrizzleMigrations } from "../src/accountDrizzleMigrations";
import { accountMeta } from "../src/accountDrizzleSchema";
import { ACCOUNT_SQLITE_MIGRATIONS, runAccountSqliteMigrations } from "../src/accountSqliteStorage";
import { AccountControlPlane, type ControlPlaneEnv } from "../src/controlPlaneDo";

export class SandboxAccount extends AccountControlPlane {
  override async alarm(): Promise<void> {
    await this.ctx.storage.put("sandbox:alarms", (await this.ctx.storage.get<number>("sandbox:alarms") ?? 0) + 1);
    await super.alarm();
  }
  override async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === "/inspect") {
      return Response.json({
        schema: Array.from(this.ctx.storage.sql.exec("SELECT id, hash, name FROM __drizzle_migrations")),
        rows: Array.from(this.ctx.storage.sql.exec("SELECT challenge_id, expires_at FROM account_challenges")),
        alarm: await this.ctx.storage.getAlarm(),
        alarmInvocations: await this.ctx.storage.get<number>("sandbox:alarms") ?? 0,
        databaseSize: this.ctx.storage.sql.databaseSize,
      });
    }
    if (path === "/seed") {
      const { id, expiresAt, payload = "{}" } = await request.json() as { id: string; expiresAt: number; payload?: string };
      this.ctx.storage.sql.exec(
        "INSERT INTO account_challenges (challenge_id, payload, payload_bytes, expires_at) VALUES (?, ?, ?, ?)", id, payload, new TextEncoder().encode(payload).byteLength, expiresAt,
      );
      return Response.json({ ok: true });
    }
    if (path === "/fill-and-expire") {
      this.ctx.storage.transactionSync(() => {
        for (let i = 0; i < 128; i++) this.ctx.storage.sql.exec(
          "INSERT INTO account_challenges (challenge_id, payload, payload_bytes, expires_at) VALUES (?, ?, ?, ?)",
          `churn-${Date.now()}-${i}`, "x".repeat(65_536), 65_536, Date.now() - 1,
        );
      });
      return Response.json({ databaseSize: this.ctx.storage.sql.databaseSize });
    }
    if (path === "/set-alarm") {
      const { at } = await request.json() as { at: number };
      await this.ctx.storage.setAlarm(at);
      return Response.json({ ok: true });
    }
    if (path === "/alarm") {
      // The runtime removes the delivered alarm before calling alarm().
      await this.ctx.storage.deleteAlarm();
      await super.alarm();
      return Response.json({ ok: true });
    }
    return super.fetch(request);
  }
}
interface Env extends ControlPlaneEnv {
  ACCOUNT: DurableObjectNamespace<SandboxAccount>;
  SCHEMA: DurableObjectNamespace<SandboxSchema>;
  DRIZZLE: DurableObjectNamespace<SandboxDrizzle>;
  MIGRATION_STAGE: string;
}

export class SandboxSchema extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.blockConcurrencyWhile(async () => {
      const migrations = [...ACCOUNT_SQLITE_MIGRATIONS];
      if (env.MIGRATION_STAGE !== "base") migrations.push({
        version: 2, name: "test_schema_upgrade", statements: env.MIGRATION_STAGE === "bad" ? [
          "CREATE TABLE partially_applied (id TEXT)",
          "DELETE FROM account_preferences",
          "INSERT INTO missing_table VALUES (1)",
        ] : ["ALTER TABLE account_preferences ADD COLUMN note TEXT DEFAULT 'upgraded'"],
      });
      runAccountSqliteMigrations({
        sql: this.ctx.storage.sql,
        transactionSync: callback => this.ctx.storage.transactionSync(callback),
      }, Date.now(), migrations);
    });
  }
  override async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname === "/schema/seed") {
      this.ctx.storage.sql.exec("INSERT INTO account_preferences (preference_key, payload, updated_at) VALUES ('relay', 'keep', ?)", Date.now());
      await this.ctx.storage.put("old:control-state", "keep-kv");
    }
    return Response.json({
      schema: Array.from(this.ctx.storage.sql.exec("SELECT version FROM account_schema_migrations ORDER BY version")),
      preferences: Array.from(this.ctx.storage.sql.exec("SELECT * FROM account_preferences")),
      partial: Array.from(this.ctx.storage.sql.exec("SELECT name FROM sqlite_master WHERE name = 'partially_applied'")),
      kv: await this.ctx.storage.get("old:control-state"),
    });
  }
}

export class SandboxDrizzle extends DurableObject<Env> {
  private readonly db = accountDrizzleDatabase(this.ctx.storage);

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.blockConcurrencyWhile(async () => {
      migrate(accountDrizzleDatabase(this.ctx.storage), { migrations: accountDrizzleMigrations });
    });
  }

  override async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname !== "/probe") return new Response("not_found", { status: 404 });
    try {
      this.db.transaction((tx) => {
        tx.insert(accountMeta).values({ key: "route_revision", value: "first" }).run();
        tx.insert(accountMeta).values({ key: "lan_generation", value: "second" }).run();
        throw new Error("intentional rollback");
      });
    } catch (error) {
      if (!(error instanceof Error) || error.message !== "intentional rollback") throw error;
    }
    return Response.json({ rows: this.db.select().from(accountMeta).all() });
  }
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/schema/")) return env.SCHEMA.get(env.SCHEMA.idFromName("upgrade")).fetch(request);
    if (url.pathname.startsWith("/drizzle/")) {
      return env.DRIZZLE.get(env.DRIZZLE.idFromName("probe")).fetch(
        new Request(new URL(request.url).toString().replace("/drizzle", ""), request),
      );
    }
    if (url.pathname.startsWith("/api/devices/iroh")) {
      const account = url.searchParams.get("account") ?? "a";
      const headers = new Headers(request.headers);
      headers.set("x-control-account-id", account);
      return env.ACCOUNT.get(env.ACCOUNT.idFromName(account)).fetch(
        new Request(request.url, { method: request.method, headers, body: request.method === "GET" ? undefined : request.body }),
      );
    }
    const account = url.searchParams.get("account") ?? "a";
    return env.ACCOUNT.get(env.ACCOUNT.idFromName(account)).fetch(request);
  },
};
