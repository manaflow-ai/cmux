import { describe, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readMigrationFiles } from "drizzle-orm/migrator";

import {
  compareLedger,
  formatLedgerReport,
  LEDGER_EXIT,
  ledgerVerdict,
  planMigrationOverlay,
  readLocalMigrations,
} from "../scripts/cloud-vm/migration-ledger.mjs";

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const checkerCli = path.join(webDir, "scripts/cloud-vm/check-migration-ledger.mjs");
const stageCli = path.join(webDir, "scripts/cloud-vm/stage-migration-source.mjs");

function withTempDir<T>(fn: (dir: string) => T): T {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-ledger-test-"));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function writeMigration(root: string, name: string, sql: string): void {
  mkdirSync(path.join(root, name), { recursive: true });
  writeFileSync(path.join(root, name, "migration.sql"), sql);
}

const applied = (name: string, hash = "h") => ({ name, hash });

describe("local migrations", () => {
  test("match drizzle's own names, order, and hashes", () => {
    withTempDir((dir) => {
      writeMigration(dir, "20260927100000_b", "create table b ();");
      writeMigration(dir, "20260923120000_a", "alter table a add column x int;\n--> statement-breakpoint\nselect 1;");
      mkdirSync(path.join(dir, "20260930000000_not_a_migration"));
      writeFileSync(path.join(dir, "README.md"), "ignored");

      const local = readLocalMigrations(dir);
      const drizzle = readMigrationFiles({ migrationsFolder: dir });
      expect(local.map((m) => m.name)).toEqual(["20260923120000_a", "20260927100000_b"]);
      expect(local).toEqual(drizzle.map((m) => ({ name: m.name, hash: m.hash })));
    });
  });

  test("the repository's migrations are all readable", () => {
    const local = readLocalMigrations(path.join(webDir, "db/migrations"));
    expect(local.length).toBeGreaterThan(80);
    expect(local.some((m) => m.name === "20260927100000_vm_alert_hardening")).toBe(true);
  });
});

describe("ledger comparison", () => {
  const local = [
    { name: "20260921030000_hive_runtime_registry", hash: "h1" },
    { name: "20260923120000_coderouter_account_usage_cache", hash: "h2" },
    { name: "20260927100000_vm_alert_hardening", hash: "h3" },
  ];

  test("pending is selected by name, as drizzle's migrator does", () => {
    const result = compareLedger({
      local,
      applied: [applied("20260921030000_hive_runtime_registry", "h1"), applied("20260927100000_vm_alert_hardening", "h3")],
    });
    // An older name missing from the ledger is still pending: drizzle 1.0
    // compares names, not the newest applied timestamp.
    expect(result.pending.map((m) => m.name)).toEqual(["20260923120000_coderouter_account_usage_cache"]);
    expect(result.pending[0]?.introduced).toBeNull();
  });

  test("marks which pending migrations the change introduces", () => {
    const result = compareLedger({
      local,
      applied: [applied("20260921030000_hive_runtime_registry", "h1")],
      baseNames: ["20260921030000_hive_runtime_registry", "20260923120000_coderouter_account_usage_cache"],
    });
    expect(result.pending).toEqual([
      { name: "20260923120000_coderouter_account_usage_cache", introduced: false },
      { name: "20260927100000_vm_alert_hardening", introduced: true },
    ]);
  });

  test("reports edited migrations and rows applied from unmerged branches", () => {
    const result = compareLedger({
      local,
      applied: [
        applied("20260921030000_hive_runtime_registry", "h1"),
        applied("20260923120000_coderouter_account_usage_cache", "edited"),
        applied("20260927100000_vm_alert_hardening", "h3"),
        applied("20260928120000_team_invites", "h9"),
        { name: null, hash: "legacy-row-without-name" },
      ],
    });
    expect(result.pending).toEqual([]);
    expect(result.hashMismatches).toEqual(["20260923120000_coderouter_account_usage_cache"]);
    expect(result.appliedOnly).toEqual(["20260928120000_team_invites"]);
  });
});

describe("verdicts", () => {
  const introduced = { pending: [{ name: "n2", introduced: true }], hashMismatches: [], appliedOnly: [] };
  const inherited = { pending: [{ name: "n1", introduced: false }], hashMismatches: [], appliedOnly: [] };
  const clean = { pending: [], hashMismatches: [], appliedOnly: ["other-branch"] };
  const edited = { pending: [], hashMismatches: ["n1"], appliedOnly: [] };

  test("gate mode fails on any pending migration in the tree being merged", () => {
    expect(ledgerVerdict(introduced, "gate")).toEqual({ status: "fail", exitCode: LEDGER_EXIT.drift });
    expect(ledgerVerdict(inherited, "gate")).toEqual({ status: "fail", exitCode: LEDGER_EXIT.drift });
    expect(ledgerVerdict(clean, "gate")).toEqual({ status: "ok", exitCode: LEDGER_EXIT.ok });
  });

  test("pull-request mode fails only for migrations the pull request adds", () => {
    expect(ledgerVerdict(introduced, "pull-request").status).toBe("fail");
    expect(ledgerVerdict(inherited, "pull-request")).toEqual({ status: "warn", exitCode: LEDGER_EXIT.ok });
  });

  test("advisory mode never fails", () => {
    expect(ledgerVerdict(introduced, "advisory")).toEqual({ status: "warn", exitCode: LEDGER_EXIT.ok });
  });

  test("an edited applied migration warns without failing", () => {
    expect(ledgerVerdict(edited, "gate")).toEqual({ status: "warn", exitCode: LEDGER_EXIT.ok });
  });

  test("exit codes are distinct", () => {
    expect(new Set(Object.values(LEDGER_EXIT)).size).toBe(Object.keys(LEDGER_EXIT).length);
    expect(LEDGER_EXIT.ok).toBe(0);
  });
});

describe("report", () => {
  test("a failing report names each migration and the operator sequence", () => {
    const result = {
      pending: [
        { name: "20260923120000_coderouter_account_usage_cache", introduced: false },
        { name: "20260927100000_vm_alert_hardening", introduced: true },
      ],
      hashMismatches: [],
      appliedOnly: [],
    };
    const report = formatLedgerReport({
      target: "production",
      result,
      verdict: ledgerVerdict(result, "gate"),
      sourceRef: "0123456789abcdef0123456789abcdef01234567",
      repository: "manaflow-ai/cmux",
    });
    expect(report).toContain("production is missing 2 migrations");
    expect(report).toContain("20260927100000_vm_alert_hardening (added by this change)");
    expect(report).toContain("20260923120000_coderouter_account_usage_cache (already on the base branch)");
    const staging = report.indexOf("target=staging");
    const production = report.indexOf("target=production");
    const merge = report.indexOf("re-run this check");
    expect(staging).toBeGreaterThan(0);
    expect(production).toBeGreaterThan(staging);
    expect(merge).toBeGreaterThan(production);
    expect(report).toContain(
      "gh workflow run cloud-vm-migrate.yml --repo manaflow-ai/cmux --ref main -f target=staging -f source_ref=0123456789abcdef0123456789abcdef01234567",
    );
    expect(report).toContain("bun run cloud-vm:migrate -- production");
  });

  test("a clean report says so and lists unmerged applied rows", () => {
    const result = { pending: [], hashMismatches: [], appliedOnly: ["20260928120000_team_invites"] };
    const report = formatLedgerReport({ target: "staging", result, verdict: ledgerVerdict(result, "advisory") });
    expect(report).toContain("staging has every migration in this tree");
    expect(report).toContain("20260928120000_team_invites");
  });
});

describe("migration overlay", () => {
  test("adds new source migrations, keeps base-only ones, and refuses edits", () => {
    const base = new Map([
      ["m1", new Map([["migration.sql", "blob1"]])],
      ["m3", new Map([["migration.sql", "blob3"]])],
    ]);
    const source = new Map([
      ["m1", new Map([["migration.sql", "blob1"]])],
      ["m2", new Map([["migration.sql", "blob2"], ["snapshot.json", "snap2"]])],
    ]);
    expect(planMigrationOverlay({ base, source })).toEqual({ add: ["m2"], conflicts: [] });

    const edited = new Map([["m1", new Map([["migration.sql", "blob1-edited"]])]]);
    expect(planMigrationOverlay({ base, source: edited })).toEqual({ add: [], conflicts: ["m1"] });
  });
});

describe("check-migration-ledger CLI", () => {
  function run(args: string[], env: Record<string, string> = {}) {
    const childEnv: NodeJS.ProcessEnv = { NODE_ENV: "test", PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "", CMUX_CLOUD_VM_ENV_SOURCE: "process", ...env };
    return spawnSync("bun", [checkerCli, ...args], { cwd: webDir, env: childEnv, encoding: "utf8" });
  }

  test("rejects unknown arguments with the usage exit code", () => {
    expect(run(["production", "--bogus"]).status).toBe(LEDGER_EXIT.usage);
    expect(run(["production", "--mode", "loose"]).status).toBe(LEDGER_EXIT.usage);
  });

  test("fails closed when production cannot be read", () => {
    const result = run(["production", "--mode", "gate"]);
    expect(result.status).toBe(LEDGER_EXIT.unverified);
    expect(result.stderr).toContain("could not read the production migration ledger");
  });

  test("advisory mode reports an unreadable staging ledger without failing", () => {
    const result = run(["staging", "--mode", "advisory"]);
    expect(result.status).toBe(LEDGER_EXIT.ok);
    expect(`${result.stdout}${result.stderr}`).toContain("could not read the staging migration ledger");
  });

  test("never prints the database URL", () => {
    const secret = "postgres://ledger:s3cr3t-value@example.invalid:5432/postgres";
    const result = run(["production"], { DATABASE_URL: secret });
    expect(result.status).toBe(LEDGER_EXIT.unverified);
    expect(`${result.stdout}${result.stderr}`).not.toContain("s3cr3t-value");
  });
});

describe("stage-migration-source CLI", () => {
  function git(cwd: string, ...args: string[]): string {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid" },
    }).trim();
  }

  function repoWithBranch(dir: string, sourceSql: Record<string, string>): { base: string; source: string } {
    git(dir, "init", "-q", "-b", "main");
    const migrations = path.join(dir, "web/db/migrations");
    writeMigration(migrations, "m1", "select 1;");
    git(dir, "add", ".");
    git(dir, "commit", "-q", "-m", "base");
    git(dir, "checkout", "-q", "-b", "feature");
    for (const [name, sql] of Object.entries(sourceSql)) writeMigration(migrations, name, sql);
    git(dir, "add", ".");
    git(dir, "commit", "-q", "-m", "feature");
    const source = git(dir, "rev-parse", "HEAD");
    git(dir, "checkout", "-q", "main");
    // main moves on after the branch point; its migration must survive.
    writeMigration(migrations, "m0_main_only", "select 0;");
    git(dir, "add", ".");
    git(dir, "commit", "-q", "-m", "main moves");
    return { base: git(dir, "rev-parse", "HEAD"), source };
  }

  test("copies only the new source migrations into the base tree", () => {
    withTempDir((dir) => {
      const { base, source } = repoWithBranch(dir, { m2: "create table two ();" });
      const result = spawnSync("bun", [stageCli, "--repo", dir, "--base", base, "--source", source], { encoding: "utf8" });
      expect(result.status).toBe(0);
      const migrations = path.join(dir, "web/db/migrations");
      expect(readFileSync(path.join(migrations, "m2/migration.sql"), "utf8")).toBe("create table two ();");
      expect(readLocalMigrations(migrations).map((m) => m.name)).toEqual(["m0_main_only", "m1", "m2"]);
      expect(result.stdout).toContain("m2");
    });
  });

  test("refuses a source that edits a migration already on the base", () => {
    withTempDir((dir) => {
      const { base, source } = repoWithBranch(dir, { m1: "select 'edited';" });
      const result = spawnSync("bun", [stageCli, "--repo", dir, "--base", base, "--source", source], { encoding: "utf8" });
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("m1");
      expect(readFileSync(path.join(dir, "web/db/migrations/m1/migration.sql"), "utf8")).toBe("select 1;");
    });
  });
});
