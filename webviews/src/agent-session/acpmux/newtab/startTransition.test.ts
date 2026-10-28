import { expect, test } from "bun:test";
import { startNewTabTransition } from "./startTransition";

test("keeps the New Tab until chat.new resolves", async () => {
  let resolve!: (value: string) => void;
  let left = false;
  const pending = startNewTabTransition(
    () => new Promise<string>((done) => (resolve = done)),
    () => {
      left = true;
    },
  );
  expect(left).toBe(false);
  resolve("session-1");
  await expect(pending).resolves.toBe("session-1");
  expect(left).toBe(true);
});

test("leaves the New Tab after a refused chat.new so the composer can recover", async () => {
  let left = false;
  const pending = startNewTabTransition(
    async () => {
      throw new Error("start refused");
    },
    () => {
      left = true;
    },
  );
  await expect(pending).rejects.toThrow("start refused");
  expect(left).toBe(true);
});
