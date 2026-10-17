import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { projects } from "../scripts/cloud-vm/projects.mjs";

// Runs the real deploy gate CLI against the migrated test database
// (bun scripts/db-migrate.mjs), then removes one OLDER ledger row behind newer
// applied ones, the 2026-10-01 incident shape, and expects the gate to fail.
const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const gateScript = path.join(webDir, "tools/migration-deploy-gate.mjs");

function runGate(): { code: number; out: string } {
  const result = spawnSync("bun", [gateScript], {
    encoding: "utf8",
    cwd: webDir,
    env: {
      NODE_ENV: "production",
      PATH: process.env.PATH ?? "",
      HOME: process.env.HOME ?? "",
      VERCEL: "1",
      VERCEL_ENV: "production",
      VERCEL_PROJECT_ID: projects.production.projectId,
      VERCEL_GIT_COMMIT_SHA: "0123456789abcdef0123456789abcdef01234567",
      DATABASE_URL: process.env.DIRECT_DATABASE_URL || process.env.DATABASE_URL || "",
    },
  });
  return { code: result.status ?? -1, out: `${result.stdout}${result.stderr}` };
}

describe("migration deploy gate against a migrated database", () => {
  dbTest("passes when the ledger is complete and fails when an older migration is missing", async () => {
    expect(runGate()).toMatchObject({ code: 0 });

    const { Client } = createRequire(path.join(webDir, "package.json"))("pg");
    const client = new Client({ connectionString: process.env.DIRECT_DATABASE_URL || process.env.DATABASE_URL });
    await client.connect();
    try {
      const rows = (await client.query("select id, hash, created_at, name from drizzle.__drizzle_migrations order by name")).rows;
      expect(rows.length).toBeGreaterThan(2);
      const victim = rows[rows.length - 2];
      await client.query("delete from drizzle.__drizzle_migrations where id = $1", [victim.id]);
      try {
        const run = runGate();
        expect(run.code).toBe(1);
        expect(run.out).toContain(victim.name);
      } finally {
        await client.query(
          "insert into drizzle.__drizzle_migrations (id, hash, created_at, name) values ($1, $2, $3, $4)",
          [victim.id, victim.hash, victim.created_at, victim.name],
        );
      }
      expect(runGate()).toMatchObject({ code: 0 });
    } finally {
      await client.end();
    }
  });
});
