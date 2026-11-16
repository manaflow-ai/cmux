/**
 * The mesh apply coverage and the writer lock are read-modify-writes on one ledger key. Each must run in one ledger
 * transaction: concurrent calls through the in-memory layer interleaved between their read and their write, so two
 * attaches could get one `need` (one of them never covered by its own number) and two writers could both take the lock.
 * The coalescing test then passed with one apply without exercising a real counter (#41517 review F1).
 */
import { expect, it } from "vitest";
import { memoryLedgerStorage, TenantLedger } from "../../src/limits/ledger.ts";

const N = 50;
const ledger = () => new TenantLedger(memoryLedgerStorage());

it("concurrent coverage wants each get their own number, 1 to N", async () => {
  const l = ledger();
  const needs = await Promise.all(Array.from({ length: N }, () => l.coverageWant("mesh")));
  expect([...needs].sort((a, b) => a - b)).toEqual(Array.from({ length: N }, (_, i) => i + 1));
  expect(await l.coverageWanted("mesh")).toBe(N);
});

it("concurrent applies keep the highest number, and a want after them counts past it", async () => {
  const l = ledger();
  await Promise.all(Array.from({ length: N }, () => l.coverageWant("mesh")));
  await Promise.all(Array.from({ length: N }, (_, i) => l.coverageApplied("mesh", i + 1)));
  // Every need up to N is covered; the next want is not.
  expect(await l.lockUnlessCovered("lock", "w", 1_000, 0, "mesh", N)).toBe("covered");
  const next = await l.coverageWant("mesh");
  expect(next).toBe(N + 1);
  expect(await l.lockUnlessCovered("lock", "w", 1_000, 0, "mesh", next)).toBe("taken");
});

it("concurrent wants and applies interleaved: every want stays unique and applied never passes wanted", async () => {
  const l = ledger();
  const needs = await Promise.all(Array.from({ length: N }, async (_, i) => {
    const need = await l.coverageWant("mesh");
    if (i % 3 === 0) await l.coverageApplied("mesh", await l.coverageWanted("mesh"));
    return need;
  }));
  expect(new Set(needs).size).toBe(N);
  expect(await l.coverageWanted("mesh")).toBe(N);
});

it("concurrent writers for one lock: exactly one takes it", async () => {
  const l = ledger();
  const taken = await Promise.all(Array.from({ length: N }, (_, i) => l.lock("lock", `writer-${i}`, 60_000, 0)));
  expect(taken.filter(Boolean)).toHaveLength(1);
  const tries = await Promise.all(Array.from({ length: N }, (_, i) => l.lockUnlessCovered("lock2", `w-${i}`, 60_000, 0, "none", 1)));
  expect(tries.filter((t) => t === "taken")).toHaveLength(1);
});
