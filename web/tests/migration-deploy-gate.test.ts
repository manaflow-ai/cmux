import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  BREAK_GLASS_ENV,
  DEFAULT_WAIT_SECONDS,
  WAIT_SECONDS_ENV,
  gatedProjects,
  missingMigrationNames,
  readAppliedMigrationNames,
  resolveGateMode,
  resolveWaitMs,
  runMigrationGate,
} from "../tools/migration-deploy-gate.mjs";
import { projects } from "../scripts/cloud-vm/projects.mjs";
import packageJSON from "../package.json";

// The 2026-11-18 outage: #42784 and #44965 shipped code reading
// apple_subscriptions.carried_* while production lacked
// 20261116120000_apple_iap_carried_plan. These cases pin that a production
// build cannot go live ahead of its migrations, and waits for the automatic
// migration run instead of failing at once.

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const productionId = projects.production.projectId;
const stagingId = projects.staging.projectId;
const commitSha = "0123456789abcdef0123456789abcdef01234567";
const secretUrl = "postgres://gate-user:hunter2-secret@db.example.test:6432/postgres?sslmode=verify-full";

const scratchDirs: string[] = [];
afterEach(() => {
  for (const dir of scratchDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

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

type GateRun = { code: number; out: string; reads: number; urls: string[]; sleptMs: number };

/**
 * Runs the gate on a fake clock. `ledger` is called once per read with the
 * read number (1-based) and returns the applied names or throws.
 */
async function gate(env: Record<string, string | undefined>, options: {
  local?: string[];
  ledger?: (read: number) => (string | null)[];
} = {}): Promise<GateRun> {
  const lines: string[] = [];
  const urls: string[] = [];
  let reads = 0;
  let clock = 0;
  let sleptMs = 0;
  const code = await runMigrationGate({
    env,
    webDir: options.local ? fakeWebDir(options.local) : webDir,
    readAppliedNames: async (connectionString: string) => {
      reads += 1;
      urls.push(connectionString);
      return (options.ledger ?? (() => []))(reads);
    },
    now: () => clock,
    sleep: async (ms: number) => {
      clock += ms;
      sleptMs += ms;
    },
    pollMs: 20_000,
    log: (line: string) => lines.push(line),
    error: (line: string) => lines.push(line),
  });
  return { code, out: lines.join("\n"), reads, urls, sleptMs };
}

const a = "20261113120000_apple_iap_recheck_backfill";
const b = "20261116120000_apple_iap_carried_plan";
const c = "20261117120000_later_expand";

describe("gate mode", () => {
  test("skips outside Vercel, previews, and the docs projects", () => {
    expect(resolveGateMode({}).action).toBe("skip");
    expect(resolveGateMode({ VERCEL: "1", VERCEL_ENV: "preview", VERCEL_PROJECT_ID: productionId }).action).toBe("skip");
    expect(resolveGateMode({ VERCEL: "1", VERCEL_ENV: "production", VERCEL_PROJECT_ID: "prj_docs" }).action).toBe("skip");
  });

  test("checks production and staging, and fails closed without a project id", () => {
    expect(resolveGateMode(productionBuildEnv())).toMatchObject({ action: "check", label: "production", branch: "main" });
    expect(resolveGateMode(productionBuildEnv({ VERCEL_PROJECT_ID: stagingId }))).toMatchObject({ action: "check", label: "staging" });
    expect(resolveGateMode(productionBuildEnv({ VERCEL_PROJECT_ID: undefined })).action).toBe("fail");
    // System env vars not exposed: cannot tell production from preview, so fail rather than skip.
    expect(resolveGateMode(productionBuildEnv({ VERCEL_ENV: undefined })).action).toBe("fail");
  });

  test("gated project ids match scripts/cloud-vm/projects.mjs", () => {
    const byId: Record<string, { projectName: string } | undefined> = gatedProjects;
    expect(byId[productionId]?.projectName).toBe(projects.production.projectName);
    expect(byId[stagingId]?.projectName).toBe(projects.staging.projectName);
  });

  test("the Vercel build runs the gate after next build", () => {
    const command = packageJSON.scripts["vercel-build"];
    const gateAt = command.indexOf("bun tools/migration-deploy-gate.mjs");
    expect(gateAt).toBeGreaterThan(command.indexOf("next build"));
    expect(command.slice(gateAt - 4, gateAt)).toBe(" && ");
  });
});

describe("missing migrations", () => {
  test("uses drizzle's name rule, so an older migration behind newer applied ones counts", () => {
    expect(missingMigrationNames([a, b, c], [a, c])).toEqual([b]);
    expect(missingMigrationNames([a, b], [a, b, c])).toEqual([]);
  });

  test("the real migrations folder includes the migration from the outage", async () => {
    const run = await gate(productionBuildEnv(), { ledger: () => [] });
    expect(run.out).toContain("20261116120000_apple_iap_carried_plan");
  });
});

describe("production build", () => {
  test("passes at once when the ledger has every migration", async () => {
    const run = await gate(productionBuildEnv(), { local: [a, b], ledger: () => [a, b] });
    expect(run).toMatchObject({ code: 0, reads: 1, sleptMs: 0 });
    expect(run.out).toContain("production database has all 2 required migration(s)");
  });

  test("waits for the migration run and passes once it lands", async () => {
    const run = await gate(productionBuildEnv(), {
      local: [a, b],
      ledger: (read) => (read < 4 ? [a] : [a, b]),
    });
    expect(run.code).toBe(0);
    expect(run.reads).toBe(4);
    expect(run.sleptMs).toBe(60_000);
    expect(run.out).toContain(`missing ${b}`);
    // One waiting line, not one per poll.
    expect(run.out.match(/not ready/g)?.length).toBe(1);
  });

  test("fails, naming the migration, when the wait ends first", async () => {
    const run = await gate(productionBuildEnv({ [WAIT_SECONDS_ENV]: "60" }), { local: [a, b], ledger: () => [a] });
    expect(run.code).toBe(1);
    expect(run.sleptMs).toBe(60_000);
    expect(run.out).toContain("still lacks 1 migration(s)");
    expect(run.out).toContain(`  ${b}`);
    expect(run.out).toContain("Vercel keeps the previous deployment live");
  });

  test("the default wait is 20 minutes and a bad value cannot disable it", () => {
    expect(DEFAULT_WAIT_SECONDS).toBe(1200);
    expect(resolveWaitMs({})).toBe(1_200_000);
    expect(resolveWaitMs({ [WAIT_SECONDS_ENV]: "-1" })).toBe(1_200_000);
    expect(resolveWaitMs({ [WAIT_SECONDS_ENV]: "abc" })).toBe(1_200_000);
    expect(resolveWaitMs({ [WAIT_SECONDS_ENV]: "99999" })).toBe(1_800_000);
  });

  test("retries a transient read failure, then passes", async () => {
    const refused = Object.assign(new Error(`connect ECONNREFUSED ${secretUrl}`), { code: "ECONNREFUSED" });
    const run = await gate(productionBuildEnv(), {
      local: [a],
      ledger: (read) => {
        if (read === 1) throw refused;
        return [a];
      },
    });
    expect(run.code).toBe(0);
    expect(run.out).toContain("read failed (ECONNREFUSED)");
    expect(run.out).not.toContain("hunter2");
  });

  test("fails closed at once on a permission error, without printing credentials", async () => {
    const denied = Object.assign(new Error(`permission denied for ${secretUrl}`), { code: "42501" });
    const run = await gate(productionBuildEnv(), {
      local: [a],
      ledger: () => {
        throw denied;
      },
    });
    expect(run).toMatchObject({ code: 1, reads: 1, sleptMs: 0 });
    expect(run.out).toContain("could not read the production migration ledger (42501)");
    expect(run.out).not.toContain("hunter2");
    expect(run.out).not.toContain("db.example.test");
  });

  test("an unreachable database fails closed when the wait ends", async () => {
    const run = await gate(productionBuildEnv({ [WAIT_SECONDS_ENV]: "40" }), {
      local: [a],
      ledger: () => {
        throw Object.assign(new Error("timeout"), { code: "ETIMEDOUT" });
      },
    });
    expect(run.code).toBe(1);
    expect(run.out).toContain("(ETIMEDOUT); failing closed");
  });

  test("reads the URL the runtime uses: DIRECT_DATABASE_URL, then DATABASE_URL", async () => {
    const direct = "postgres://direct@db.example.test:5432/postgres";
    expect((await gate(productionBuildEnv({ DIRECT_DATABASE_URL: direct }), { local: [a], ledger: () => [a] })).urls).toEqual([direct]);
    expect((await gate(productionBuildEnv(), { local: [a], ledger: () => [a] })).urls).toEqual([secretUrl]);
  });

  test("fails closed without a database URL", async () => {
    const run = await gate(productionBuildEnv({ DATABASE_URL: undefined }), { local: [a] });
    expect(run).toMatchObject({ code: 1, reads: 0 });
  });

  test("staging checks its own database", async () => {
    const run = await gate(productionBuildEnv({ VERCEL_PROJECT_ID: stagingId, [WAIT_SECONDS_ENV]: "0" }), { local: [a, b], ledger: () => [a] });
    expect(run.code).toBe(1);
    expect(run.out).toContain("the staging database still lacks");
  });

  test("previews never read a database", async () => {
    const run = await gate(productionBuildEnv({ VERCEL_ENV: "preview" }), { local: [a] });
    expect(run).toMatchObject({ code: 0, reads: 0 });
  });
});

describe("break-glass", () => {
  test("skips the check for the named commit only", async () => {
    const run = await gate(productionBuildEnv({ [BREAK_GLASS_ENV]: commitSha.slice(0, 12) }), { local: [a] });
    expect(run).toMatchObject({ code: 0, reads: 0 });
    expect(run.out).toContain("BREAK-GLASS");
  });

  test("a value left from an earlier commit is ignored", async () => {
    const run = await gate(productionBuildEnv({ [BREAK_GLASS_ENV]: "fedcba9", [WAIT_SECONDS_ENV]: "0" }), { local: [a], ledger: () => [] });
    expect(run.code).toBe(1);
    expect(run.out).toContain("ignoring it");
  });
});

test("an unreachable real database fails without printing the URL", async () => {
  let message = "";
  try {
    await readAppliedMigrationNames("postgres://gate-user:hunter2-secret@127.0.0.1:1/postgres", { timeoutMs: 2_000 });
  } catch (error) {
    message = String((error as { code?: string }).code);
  }
  expect(message).toBe("ECONNREFUSED");
});

test("the gate lives where Vercel can run it", () => {
  // The root .vercelignore drops every scripts/ directory from the build.
  const vercelignore = readFileSync(path.join(webDir, "..", ".vercelignore"), "utf8");
  expect(vercelignore.split("\n")).toContain("scripts/");
  expect(packageJSON.scripts["vercel-build"]).not.toContain("scripts/");
});
