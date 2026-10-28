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

test("does not block a prompt queued beside a deferred start", async () => {
  let resolve!: (value: string) => void;
  const order: string[] = [];
  const started = startNewTabTransition(
    () =>
      new Promise<string>((done) => {
        resolve = (value) => {
          order.push("start-resolved");
          done(value);
        };
      }),
    () => order.push("leave"),
  );
  order.push("send");
  expect(order).toEqual(["send"]);
  resolve("session-1");
  await expect(started).resolves.toBe("session-1");
  expect(order).toEqual(["send", "start-resolved", "leave"]);
});
