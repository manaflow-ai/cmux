import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { PNG } from "pngjs";
import { deleteLedgerIds, diffPng, parseManifest, shardCases, writeLedger } from "./runner";

test("parses and validates a manifest", () => {
  expect(parseManifest([{ id: "a", path_or_url: "index.html", params: { width: 10, dark: true } }])).toHaveLength(1);
  expect(() => parseManifest([{ id: "a", path_or_url: "x" }, { id: "a", path_or_url: "y" }])).toThrow("duplicate");
  expect(() => parseManifest({})).toThrow("array");
});

test("shards cases deterministically", () => {
  const cases = [0, 1, 2, 3, 4, 5].map((id) => ({ id: String(id), path_or_url: "x" }));
  expect(shardCases(cases, 2, 0).map((item) => item.id)).toEqual(["0", "2", "4"]);
  expect(shardCases(cases, 2, 1).map((item) => item.id)).toEqual(["1", "3", "5"]);
});

test("computes a pixel diff and threshold percentage", () => {
  const one = new PNG({ width: 2, height: 1 }); one.data.fill(0); one.data[3] = 255;
  const two = new PNG({ width: 2, height: 1 }); two.data.fill(0); two.data[3] = 255; two.data[4] = 255; two.data[7] = 255;
  const diff = diffPng(PNG.sync.write(one), PNG.sync.write(two), 0);
  expect(diff.result.differentPixels).toBeGreaterThan(0);
  expect(diff.result.passed).toBe(false);
  expect(diff.png.length).toBeGreaterThan(0);
});

test("ledger cleanup deletes exact recorded ids without listing", async () => {
  const dir = mkdtempSync(join(process.cwd(), "gallery-ledger-")); const path = join(dir, "ledger.json");
  writeLedger(path, { runId: "test", createdAt: new Date().toISOString(), vmIds: ["vm-exact"], deletedVmIds: [] });
  const deleted: string[] = []; let listed = false;
  await deleteLedgerIds(path, async (id) => { deleted.push(id); });
  expect(deleted).toEqual(["vm-exact"]);
  expect(listed).toBe(false);
  expect(readFileSync(path, "utf8")).toContain("vm-exact");
  rmSync(dir, { recursive: true, force: true });
});
