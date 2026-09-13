import { expect, mock, test } from "bun:test";
const realDb = { ...await import("../db/client") };
let rows: Array<{ plan?: string }> = [];
mock.module("../db/client", () => ({ ...realDb, cloudDb: () => ({ select: () => ({ from: () => ({ where: () => Object.assign(Promise.resolve(rows), {
  limit: async (n: number) => rows.slice(0, n),
}) }) }) }) }));
const { activePersonalPlanForUser } = await import("../services/billing/pro");

test("Max wins even after more matching subscriptions than plan types", async () => {
  rows = [...Array.from({ length: 8 }, () => ({ plan: "pro" })), { plan: "max" }];
  expect(await activePersonalPlanForUser("u")).toBe("max");
});
test("missing plan data grants no exact subscription", async () => {
  rows = [{}];
  expect(await activePersonalPlanForUser("u")).toBeNull();
});
