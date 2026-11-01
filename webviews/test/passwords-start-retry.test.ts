// The Passwords page opened while the host link was down: its change subscription fails, the page
// shows the disconnected state, and when the link comes back it finishes starting, reads the lists
// and follows the app's changes. It used to stay empty (the failed start was never retried).
import { expect, test } from "bun:test";
import { PasswordOps } from "../src/pages/passwords/types";
import { PasswordsStore } from "../src/pages/passwords/store";
import { PAGE_CONNECTION, LINK_CLOSED } from "../src/pages/shared/pageStreams";
import type { PageClient } from "../src/pages/shared/pageClient";

const tick = () => new Promise<void>((done) => setTimeout(done, 0));

function linkClosed(): Error {
  return Object.assign(new Error("The link is closed."), { code: LINK_CLOSED });
}

test("a start that failed while the link was down finishes when the link returns", async () => {
  let linkUp = false;
  const listeners = new Map<string, (data: unknown, seq: number) => void>();
  const reads: string[] = [];
  const client = {
    call: async (op: string) => {
      reads.push(op);
      if (op === PasswordOps.state) {
        return {
          profiles: [{ id: "default", name: "Default" }],
          profile: "default",
          sections: { passwords: true, passkeys: false, exceptions: false, export: false },
        };
      }
      if (op === PasswordOps.list) {
        return {
          passwords: [
            {
              id: "1",
              site: "example.com",
              url: "https://example.com",
              username: "ada",
              created: null,
              last_used: null,
              times_used: 0,
              weak: false,
              reused: false,
            },
          ],
        };
      }
      return null;
    },
    subscribe: async (stream: string, onEvent: (data: unknown, seq: number) => void) => {
      if (stream === PasswordOps.changed && !linkUp) throw linkClosed();
      listeners.set(stream, onEvent);
      return () => void listeners.delete(stream);
    },
    handle: () => () => {},
  } as unknown as PageClient;

  const store = new PasswordsStore(client);
  const stop = store.subscribe(() => {});
  await tick();
  expect(store.getSnapshot().connection).toBe("disconnected");
  expect(store.getSnapshot().passwords).toEqual([]);

  linkUp = true;
  listeners.get(PAGE_CONNECTION)?.({ connected: true }, 1);
  await tick();
  await tick();

  expect(store.getSnapshot().connection).toBe("connected");
  expect(store.getSnapshot().passwords.map((row) => row.username)).toEqual(["ada"]);
  // It follows the app's changes now: a change event reads the lists again.
  const before = reads.filter((op) => op === PasswordOps.list).length;
  listeners.get(PasswordOps.changed)?.({ revision: 2 }, 2);
  await tick();
  await tick();
  expect(reads.filter((op) => op === PasswordOps.list).length).toBe(before + 1);
  stop();
});

test("a reconnect while the first change subscription is pending subscribes once", async () => {
  let release!: () => void;
  const gate = new Promise<void>((done) => (release = done));
  let changeSubscriptions = 0;
  let activeChanges = 0;
  const listeners = new Map<string, (data: unknown, seq: number) => void>();
  const client = {
    call: async (op: string) =>
      op === PasswordOps.state
        ? { profiles: [{ id: "default", name: "Default" }], profile: "default", sections: { passwords: false } }
        : null,
    subscribe: async (stream: string, onEvent: (data: unknown, seq: number) => void) => {
      if (stream === PasswordOps.changed) {
        changeSubscriptions += 1;
        await gate;
        activeChanges += 1;
        return () => void (activeChanges -= 1);
      }
      listeners.set(stream, onEvent);
      return () => void listeners.delete(stream);
    },
    handle: () => () => {},
  } as unknown as PageClient;
  const store = new PasswordsStore(client);
  const stop = store.subscribe(() => {});
  await tick();
  // The link drops and returns while the change subscription is still pending.
  listeners.get(PAGE_CONNECTION)?.({ connected: false }, 1);
  listeners.get(PAGE_CONNECTION)?.({ connected: true }, 2);
  await tick();
  release();
  await tick();
  await tick();
  expect(changeSubscriptions).toBe(1);
  expect(activeChanges).toBe(1);
  stop();
  expect(activeChanges).toBe(0);
});
