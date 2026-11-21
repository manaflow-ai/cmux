import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { drizzle } from "drizzle-orm/postgres-js";
import postgres, { type Sql } from "postgres";
import * as schema from "../db/schema";
import type { cloudDb } from "../db/client";
import { postgresNativeSignInCodeStore } from "../app/lib/native-sign-in-code-store";
import {
  hashNativeSignInCode,
  issueNativeSignInCode,
  redeemNativeSignInCode,
  restoreNativeSignInCode,
  s256CodeChallenge,
} from "../app/lib/native-sign-in-codes";

// Runs against a real Postgres with the migrations applied
// (scripts/run-db-behavior-tests.sh sets CMUX_DB_TEST=1).
const dbTest = process.env.CMUX_DB_TEST === "1" ? test : test.skip;
const VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const CHALLENGE = s256CodeChallenge(VERIFIER);
const ISSUER = "project-db-test";
let sql: Sql;
let store: ReturnType<typeof postgresNativeSignInCodeStore>;

beforeAll(() => {
  if (process.env.CMUX_DB_TEST !== "1") return;
  // Two connections at least, so the racing consumes really run concurrently.
  sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 4 });
  const db = drizzle({ client: sql, schema }) as unknown as ReturnType<typeof cloudDb>;
  store = postgresNativeSignInCodeStore(() => db);
});
beforeEach(async () => {
  if (sql) await sql`truncate native_sign_in_codes`;
});
afterAll(async () => {
  await sql?.end();
});

async function issue(): Promise<string> {
  return issueNativeSignInCode(store, { userId: "u1", codeChallenge: CHALLENGE, scheme: "cmux", issuer: ISSUER });
}

dbTest("of two concurrent consumes for one code, exactly one wins", async () => {
  for (let round = 0; round < 20; round++) {
    const code = await issue();
    const hash = hashNativeSignInCode(code);
    const now = new Date();

    const results = await Promise.all([store.consume(hash, now), store.consume(hash, now)]);

    expect(results.filter((row) => row !== null)).toHaveLength(1);
    const [rows] = await sql`select count(*)::int as n from native_sign_in_codes where code_hash = ${hash}`;
    expect(rows.n).toBe(0);
  }
});

dbTest("of two concurrent redemptions with the right verifier, exactly one succeeds", async () => {
  const code = await issue();
  const redeem = () => redeemNativeSignInCode(store, { code, codeVerifier: VERIFIER, scheme: "cmux", issuer: ISSUER });

  const results = await Promise.all([redeem(), redeem(), redeem()]);

  expect(results.filter((result) => result !== null)).toHaveLength(1);
});

dbTest("a code put back after a failed session redeems again, once", async () => {
  const code = await issue();
  const input = { code, codeVerifier: VERIFIER, scheme: "cmux", issuer: ISSUER };

  const first = await redeemNativeSignInCode(store, input);
  expect(first?.userId).toBe("u1");
  expect(first?.record.issuer).toBe(ISSUER);
  // The mint failed: the handler restores the consumed row.
  await restoreNativeSignInCode(store, first!.record);

  const retry = await redeemNativeSignInCode(store, input);
  expect(retry?.userId).toBe("u1");
  expect(await redeemNativeSignInCode(store, input)).toBeNull();
});

dbTest("an expired code is neither consumed nor put back", async () => {
  const code = await issue();
  const later = () => Date.now() + 61_000;

  expect(await redeemNativeSignInCode(store, { code, codeVerifier: VERIFIER, scheme: "cmux", issuer: ISSUER }, later)).toBeNull();

  const fresh = await issue();
  const redeemed = await redeemNativeSignInCode(store, { code: fresh, codeVerifier: VERIFIER, scheme: "cmux", issuer: ISSUER });
  await restoreNativeSignInCode(store, redeemed!.record, later);
  const [rows] = await sql`select count(*)::int as n from native_sign_in_codes where code_hash = ${hashNativeSignInCode(fresh)}`;
  expect(rows.n).toBe(0);
});

dbTest("the table refuses a row with no issuer", async () => {
  await expect(
    store.insert({
      codeHash: "a".repeat(64),
      codeChallenge: CHALLENGE,
      scheme: "cmux",
      userId: "u1",
      issuer: "",
      expiresAt: new Date(Date.now() + 60_000),
    }),
  ).rejects.toThrow();
});
