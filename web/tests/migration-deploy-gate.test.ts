import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  BREAK_GLASS_ENV,
  gatedProjects,
  missingMigrationNames,
  readAppliedMigrationNames,
  resolveGateMode,
  runMigrationGate,
} from "../tools/migration-deploy-gate.mjs";
import { projects } from "../scripts/cloud-vm/projects.mjs";

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const productionId = projects.production.projectId;
const stagingId = projects.staging.projectId;
const commitSha = "0123456789abcdef0123456789abcdef01234567";
const secretUrl = "postgres://gate-user:hunter2-secret@db.example.test:6432/postgres?sslmode=verify-full";

const scratchDirs: string[] = [];
afterEach(() => {
  for (const dir of scratchDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** Creates a web dir whose db/migrations folder holds the named migrations. */
function fakeWebDir(names: string[]): string {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-migration-gate-"));
  scratchDirs.push(dir);
  for (const name of names) {
    mkdirSync(path.join(dir, "db/migrations", name), { recursive: true });
    writeFileSync(path.join(dir, "db/migrations", name, "migration.sql"), `select '${name}';`);
  }
  return dir;
}

function productionBuildEnv(overrides: Record<string, string | undefined> = {}): Record<string, string | undefined> {
  return {
    VERCEL: "1",
    VERCEL_ENV: "production",
    VERCEL_PROJECT_ID: productionId,
    VERCEL_GIT_COMMIT_SHA: commitSha,
    DATABASE_URL: secretUrl,
    ...overrides,
  };
}

type GateRun = { code: number; out: string; reads: number; urls: string[] };

async function gate(env: Record<string, string | undefined>, options: {
  local?: string[];
  applied?: (string | null)[];
  readError?: unknown;
} = {}): Promise<GateRun> {
  const lines: string[] = [];
  const urls: string[] = [];
  let reads = 0;
  const code = await runMigrationGate({
    env,
    webDir: options.local ? fakeWebDir(options.local) : webDir,
    readAppliedNames: async (connectionString: string) => {
      reads += 1;
      urls.push(connectionString);
      if (options.readError) throw options.readError;
      return options.applied ?? [];
    },
    log: (line: string) => lines.push(line),
    error: (line: string) => lines.push(line),
  });
  return { code, out: lines.join("\n"), reads, urls };
}

const a = "20260930150000_hexclave_mirror";
const b = "20261001000000_coderouter_vm_pool_initialization";
const c = "20261001120000_coderouter_handoff_leases";

describe("migration deploy gate mode", () => {
  test("skips outside Vercel, so local and CI builds never need a database", () => {
    expect(resolveGateMode({}).action).toBe("skip");
    expect(resolveGateMode({ CI: "1", DATABASE_URL: "postgres://cmux:cmux@127.0.0.1:1/cmux" }).action).toBe("skip");
  });

  test("skips preview and development deployments of the production project", () => {
    expect(resolveGateMode(productionBuildEnv({ VERCEL_ENV: "preview" })).action).toBe("skip");
    expect(resolveGateMode(productionBuildEnv({ VERCEL_ENV: "development" })).action).toBe("skip");
  });

  test("skips production builds of other projects that share web/ (docs zones)", () => {
    expect(resolveGateMode(productionBuildEnv({ VERCEL_PROJECT_ID: "prj_docs_release" })).action).toBe("skip");
  });

  test("checks the production environment of the production and staging projects", () => {
    expect(resolveGateMode(productionBuildEnv())).toMatchObject({ action: "check", label: "production" });
    expect(resolveGateMode(productionBuildEnv({ VERCEL_PROJECT_ID: stagingId })))
      .toMatchObject({ action: "check", label: "staging" });
  });

  test("fails closed when a Vercel production build cannot identify its project", () => {
    expect(resolveGateMode(productionBuildEnv({ VERCEL_PROJECT_ID: undefined })).action).toBe("fail");
    expect(resolveGateMode(productionBuildEnv({ VERCEL_PROJECT_ID: "" })).action).toBe("fail");
  });

  test("gates exactly the staging and production Vercel projects", () => {
    expect(Object.keys(gatedProjects).sort()).toEqual([productionId, stagingId].sort());
  });
});

describe("migration deploy gate decision", () => {
  test("passes when every local migration is applied", async () => {
    const run = await gate(productionBuildEnv(), { local: [a, b, c], applied: [a, b, c, "20261002000000_newer_db_only"] });
    expect(run.code).toBe(0);
    expect(run.reads).toBe(1);
    expect(run.out).toContain("production");
  });

  test("fails with the missing migration name", async () => {
    const run = await gate(productionBuildEnv(), { local: [a, b, c], applied: [a, b] });
    expect(run.code).toBe(1);
    expect(run.out).toContain(c);
    expect(run.out).not.toContain(`  ${a}`);
  });

  test("fails when an older-timestamp migration is missing behind a newer applied one", async () => {
    const run = await gate(productionBuildEnv(), { local: [a, b, c], applied: [a, c] });
    expect(run.code).toBe(1);
    expect(run.out).toContain(b);
  });

  test("the missing-set rule matches drizzle getMigrationsToRun by name", () => {
    expect(missingMigrationNames([a, b, c], [a, c, null])).toEqual([b]);
    expect(missingMigrationNames([a, b], [a, b])).toEqual([]);
  });

  test("checks the real repository migrations folder by default", async () => {
    const run = await gate(productionBuildEnv(), { applied: [] });
    expect(run.code).toBe(1);
    expect(run.out).toContain("20260425062520_keen_kronos");
  });

  test("fails closed when the database is unreachable, without printing credentials", async () => {
    const error = Object.assign(new Error(`connect ECONNREFUSED ${secretUrl}`), { code: "ECONNREFUSED" });
    const run = await gate(productionBuildEnv(), { local: [a], readError: error });
    expect(run.code).toBe(1);
    expect(run.out).toContain("ECONNREFUSED");
    expect(run.out).toContain(BREAK_GLASS_ENV);
    expect(run.out).not.toContain("hunter2");
    expect(run.out).not.toContain("gate-user");
  });

  test("fails closed when the build has no database URL", async () => {
    const run = await gate(productionBuildEnv({ DATABASE_URL: undefined }), { local: [a] });
    expect(run.code).toBe(1);
    expect(run.reads).toBe(0);
  });

  test("reads the same URL the runtime uses, preferring DIRECT_DATABASE_URL", async () => {
    const direct = secretUrl.replace(":6432", ":5432");
    const run = await gate(productionBuildEnv({ DIRECT_DATABASE_URL: direct }), { local: [a], applied: [a] });
    expect(run.urls).toEqual([direct]);
  });

  test("break-glass for this commit passes with a loud warning and no database read", async () => {
    const run = await gate(productionBuildEnv({ [BREAK_GLASS_ENV]: commitSha.slice(0, 12) }), { local: [a] });
    expect(run.code).toBe(0);
    expect(run.reads).toBe(0);
    expect(run.out).toContain("BREAK-GLASS");
    expect(run.out).toContain(BREAK_GLASS_ENV);
  });

  test("break-glass left over from another commit does not disable the gate", async () => {
    const run = await gate(productionBuildEnv({ [BREAK_GLASS_ENV]: "fedcba9876543210" }), { local: [a], applied: [] });
    expect(run.code).toBe(1);
  });

  test("break-glass that is too short to name a commit is refused", async () => {
    const run = await gate(productionBuildEnv({ [BREAK_GLASS_ENV]: "1" }), { local: [a], applied: [] });
    expect(run.code).toBe(1);
  });

  test("preview builds skip without reading the database", async () => {
    const run = await gate(productionBuildEnv({ VERCEL_ENV: "preview" }), { local: [a] });
    expect(run.code).toBe(0);
    expect(run.reads).toBe(0);
  });
});

describe("migration ledger reader", () => {
  test("rejects an unreachable database without leaking the URL", async () => {
    const url = "postgres://gate-user:hunter2-secret@127.0.0.1:1/postgres";
    let caught: unknown;
    try {
      await readAppliedMigrationNames(url, { attempts: 1 });
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeDefined();
    const lines: string[] = [];
    const code = await runMigrationGate({
      env: productionBuildEnv({ DATABASE_URL: url }),
      webDir: fakeWebDir([a]),
      readAppliedNames: (connectionString: string) => readAppliedMigrationNames(connectionString, { attempts: 1 }),
      log: (line: string) => lines.push(line),
      error: (line: string) => lines.push(line),
    });
    expect(code).toBe(1);
    expect(lines.join("\n")).not.toContain("hunter2");
  });
});

describe("explicit read-only check (pull-request readiness)", () => {
  async function explicit(names: string[], options: { applied?: string[]; env?: Record<string, string | undefined> } = {}) {
    const lines: string[] = [];
    let reads = 0;
    const code = await runMigrationGate({
      env: options.env ?? { CMUX_MIGRATION_GATE_STAGING_DATABASE_URL: secretUrl },
      webDir,
      explicit: { label: "staging", databaseUrlEnv: "CMUX_MIGRATION_GATE_STAGING_DATABASE_URL", names },
      readAppliedNames: async () => {
        reads += 1;
        return options.applied ?? [];
      },
      log: (line: string) => lines.push(line),
      error: (line: string) => lines.push(line),
    });
    return { code, out: lines.join("\n"), reads };
  }

  test("checks only the named migrations, ignoring Vercel environment", async () => {
    const run = await explicit([b], { applied: [b] });
    expect(run.code).toBe(0);
    expect(run.reads).toBe(1);
  });

  test("fails with the named migration that is not applied", async () => {
    const run = await explicit([b, c], { applied: [c] });
    expect(run.code).toBe(1);
    expect(run.out).toContain(b);
    expect(run.out).toContain("staging");
  });

  test("fails closed when the read-only URL secret is not configured", async () => {
    const run = await explicit([b], { env: {} });
    expect(run.code).toBe(1);
    expect(run.reads).toBe(0);
    expect(run.out).toContain("CMUX_MIGRATION_GATE_STAGING_DATABASE_URL");
  });

  test("refuses names that are not migration folder names", async () => {
    const run = await explicit(["../etc/passwd"], { applied: [] });
    expect(run.code).toBe(1);
    expect(run.reads).toBe(0);
  });
});
