// An update's relaunch is a quit: the host asks every chat page `pane.wakeState` (within a second)
// before the process ends. The page waits there for the typed draft to reach acpmux, so the last
// keystroke is never a write still on its way when the app goes.
import { afterEach, expect, test } from "bun:test";
import {
  settleDraftWithin,
  settlePendingDraftWrites,
  writePersistedDraft,
} from "../src/agent-session/acpmux/composerDraft";

type Write = { sessionId: string; text: string };
const scope = globalThis as Record<string, unknown>;
const hadWindow = "window" in scope;
const savedWindow = scope.window;

function installWriter(): { landed: Write[]; release: () => void } {
  const landed: Write[] = [];
  let waiting: (() => void)[] = [];
  scope.window = {
    cmuxAcpmuxActions: {
      "chat.writeDraft": (params: Record<string, unknown>) =>
        new Promise<void>((resolve) => {
          waiting.push(() => {
            landed.push(params as Write);
            resolve();
          });
        }),
    },
  };
  return {
    landed,
    release: () => {
      const now = waiting;
      waiting = [];
      for (const run of now) run();
    },
  };
}

afterEach(() => {
  if (hadWindow) scope.window = savedWindow;
  else delete scope.window;
});

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a quit waits until acpmux holds the last keystroke, not only the first write", async () => {
  const writer = installWriter();
  writePersistedDraft("settle-a", "hel");
  writePersistedDraft("settle-a", "hello");
  let settled = false;
  const settle = settlePendingDraftWrites().then(() => {
    settled = true;
  });
  await tick();
  expect(settled).toBe(false);
  writer.release(); // "hel" lands; "hello" goes next
  await tick();
  expect(settled).toBe(false);
  writer.release(); // "hello" lands
  await settle;
  expect(writer.landed.map((write) => write.text)).toEqual(["hel", "hello"]);
});

test("nothing queued settles at once", async () => {
  installWriter();
  await settlePendingDraftWrites();
});

test("a draft write that never answers costs the quit at most the cap", async () => {
  installWriter();
  writePersistedDraft("settle-b", "stuck");
  const started = Date.now();
  await settleDraftWithin({ settleDraft: settlePendingDraftWrites }, 30);
  expect(Date.now() - started).toBeLessThan(1000);
});

test("a page without a composer answers at once", async () => {
  await settleDraftWithin(null, 10_000);
});
