import { describe, expect, test } from "bun:test";
import { createPlanetScaleOperatorPool, planetScaleOperatorOptions } from "../scripts/cloud-vm/planetscale-operator.mjs";

const pooled = "postgres://operator:secret@staging.pg.psdb.cloud:6432/postgres?sslmode=verify-full";

describe("PlanetScale operator connection", () => {
  test("uses the deployed URL without AWS credentials and selects the direct port", async () => {
    const pool = createPlanetScaleOperatorPool(process.cwd(), { DATABASE_URL: pooled }, "staging");
    try {
      const url = new URL(pool.options.connectionString!);
      expect(url.hostname).toBe("staging.pg.psdb.cloud");
      expect(url.port).toBe("5432");
      expect(url.username).toBe("operator");
      expect(pool.options.ssl).toEqual({ rejectUnauthorized: true });
      expect(pool.options.max).toBe(1);
    } finally { await pool.end(); }
  });

  test("prefers the explicitly configured direct URL", () => {
    const direct = pooled.replace("staging.pg", "direct.pg").replace(":6432", ":5432");
    expect(planetScaleOperatorOptions({ DATABASE_URL: pooled, DIRECT_DATABASE_URL: direct }, "staging")
      .connectionString).toContain("direct.pg.psdb.cloud:5432");
  });

  test("URL parameters cannot override certificate verification or the target", () => {
    const options = planetScaleOperatorOptions({ DATABASE_URL: `${pooled}&ssl=true&sslrootcert=other.pem&host=other.invalid&port=1234` }, "staging");
    const url = new URL(options.connectionString);
    expect([...url.searchParams.keys()]).toEqual([]);
    expect(url.hostname).toBe("staging.pg.psdb.cloud");
    expect(url.port).toBe("5432");
    expect(options.ssl).toEqual({ rejectUnauthorized: true });
  });

  test.each(["disable", "allow", "prefer", "no-verify"])("refuses insecure SSL mode %s", (mode) => {
    expect(() => planetScaleOperatorOptions({ DATABASE_URL: pooled.replace("verify-full", mode) }, "staging"))
      .toThrow("require certificate verification");
  });

  test("refuses the obsolete TLS bypass", () => {
    expect(() => planetScaleOperatorOptions({ DATABASE_URL: pooled, CMUX_DB_SSL_REJECT_UNAUTHORIZED: "false" }, "staging"))
      .toThrow("require certificate verification");
  });

  test.each([
    "postgres://operator:secret@example.com/postgres",
    "postgres://operator:secret@staging.pg.psdb.cloud.evil.test/postgres",
    "mysql://operator:secret@staging.pg.psdb.cloud/postgres",
    "postgres://operator@staging.pg.psdb.cloud/postgres",
    "postgres://operator:secret@staging.pg.psdb.cloud:1234/postgres",
    "not-a-url-with-secret",
  ])("refuses invalid operator target without exposing its value", (url) => {
    let message = "";
    try { planetScaleOperatorOptions({ DATABASE_URL: url }, "staging"); }
    catch (error) { message = (error as Error).message; }
    expect(message).not.toBe("");
    expect(message).not.toContain("secret");
    expect(message).not.toContain(url);
  });

  test("missing URLs never fall back to the old AWS environment", () => {
    expect(() => planetScaleOperatorOptions({ PGHOST: "database.invalid", AWS_REGION: "us-west-2" }, "staging"))
      .toThrow("DATABASE_URL or DIRECT_DATABASE_URL is required");
  });
});
