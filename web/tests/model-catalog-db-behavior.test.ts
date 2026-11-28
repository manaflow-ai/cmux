// Database-backed proof of the model catalog tables: the migration's seed is
// overrides.ts, snapshots dedupe by content hash, an override upsert replaces
// its row (also a harness row, whose model_id is null), and a publish writes a
// version only when the body changes. Gated like the other *-db-behavior tests.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import feed from "./fixtures/model-feed.json";
import { closeCloudDbForTests } from "../db/client";
import { overridesFromRows, seedRows } from "../services/model-catalog/overrideRows";
import { ingestFeed, publishCatalog } from "../services/model-catalog/publish";
import { databaseCatalogRepo } from "../services/model-catalog/repo";
import { CatalogStore, bundledSnapshot } from "../services/model-catalog/store";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const repo = databaseCatalogRepo();

let sql: Sql | null = null;

beforeAll(async () => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
  await sql`truncate catalog_versions, models_dev_snapshots restart identity cascade`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("model catalog tables", () => {
  dbTest("the migration seeds overrides.ts", async () => {
    const rows = await repo.listOverrides();
    expect(overridesFromRows(rows)).toEqual(overridesFromRows(seedRows()));
    expect(rows.every((row) => row.author === "seed" && row.active)).toBe(true);
  });

  dbTest("ingest dedupes, publish versions only on change, and the store serves the newest", async () => {
    const first = await ingestFeed(repo, feed, new Date("2026-10-07T00:00:00Z"));
    expect(first.inserted).toBe(true);
    expect((await ingestFeed(repo, feed, new Date("2026-10-07T01:00:00Z"))).inserted).toBe(false);
    const published = await publishCatalog(repo, "cron");
    expect(published).toMatchObject({ ok: true, published: true });
    expect(await publishCatalog(repo, "cron")).toMatchObject({ ok: true, published: false });
    const built = await new CatalogStore(repo, bundledSnapshot()).current();
    expect(built.catalog.source).toBe("live");
    expect(published.ok && built.etag).toBe(published.ok ? `"${published.version.contentHash}"` : false);
  });

  dbTest("an upsert replaces its row, for model and harness rows", async () => {
    const harnessRow = seedRows().find((row) => row.kind === "harness" && row.harnessId === "claude")!;
    const before = (await repo.listOverrides()).length;
    await repo.upsertOverride({ ...harnessRow, value: { ...harnessRow.value, name: "Claude Code (curated)" } }, "curator@manaflow.com");
    await repo.upsertOverride({ kind: "model", harnessId: "claude", modelId: "claude-opus-4-8", value: { hidden: true }, active: true }, "curator@manaflow.com");
    await repo.upsertOverride({ kind: "model", harnessId: "claude", modelId: "claude-opus-4-8", value: { hidden: true }, active: false }, "curator@manaflow.com");
    const rows = await repo.listOverrides();
    expect(rows.length).toBe(before + 1);
    expect(rows.find((row) => row.kind === "harness" && row.harnessId === "claude")?.value.name).toBe("Claude Code (curated)");
    expect(rows.find((row) => row.modelId === "claude-opus-4-8")?.active).toBe(false);
    expect(await publishCatalog(repo, "curator@manaflow.com")).toMatchObject({ ok: true, published: true });
  });
});
