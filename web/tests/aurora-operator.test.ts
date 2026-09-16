import { expect, test } from "bun:test";
import { createAuroraOperatorPool } from "../scripts/cloud-vm/aurora-operator.mjs";

test("operator rejects disabled certificate validation before creating an AWS token", () => {
  expect(() => createAuroraOperatorPool(process.cwd(), {
    AWS_REGION: "us-west-2",
    PGHOST: "database.invalid",
    PGPORT: "5432",
    PGUSER: "test",
    PGDATABASE: "test",
    CMUX_DB_SSL_REJECT_UNAUTHORIZED: "false",
  }, "test")).toThrow("Operator database connections require certificate validation");
});

test("PlanetScale operator uses the deployed URL without AWS credentials", async () => {
  const pool = createAuroraOperatorPool(process.cwd(), {
    CMUX_DB_DRIVER: "url",
    DATABASE_URL: "postgres://operator:secret@staging.pg.psdb.cloud:6432/postgres?sslmode=verify-full",
  }, "staging");
  try {
    const url = new URL(pool.options.connectionString!);
    expect(url.hostname).toBe("staging.pg.psdb.cloud");
    expect(url.port).toBe("5432");
    expect(pool.options.ssl).toEqual({ rejectUnauthorized: true });
    expect(pool.options.max).toBe(1);
  } finally {
    await pool.end();
  }
});
