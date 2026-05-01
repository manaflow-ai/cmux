import { expect, test } from "bun:test";
import { TerminalInputQueue, type TerminalInputQueueScheduler, type TerminalInputTarget } from "./terminalInputQueue";

class ManualScheduler implements TerminalInputQueueScheduler {
  private nextID = 1;
  private timers = new Map<number, () => void>();

  setTimeout(callback: () => void) {
    const id = this.nextID;
    this.nextID += 1;
    this.timers.set(id, callback);
    return id;
  }

  clearTimeout(timer: number) {
    this.timers.delete(timer);
  }

  runAll() {
    const callbacks = [...this.timers.values()];
    this.timers.clear();
    callbacks.forEach((callback) => callback());
  }
}

const targetA: TerminalInputTarget = { workspaceID: "workspace-a", surfaceID: "surface-a" };
const targetB: TerminalInputTarget = { workspaceID: "workspace-b", surfaceID: "surface-b" };

function targetEquals(lhs: TerminalInputTarget, rhs: TerminalInputTarget) {
  return lhs.workspaceID === rhs.workspaceID && lhs.surfaceID === rhs.surfaceID;
}

test("flushes buffered printable input before mapped keys", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "l");
  queue.appendText(targetA, "s");
  queue.sendMappedKey(targetA, "enter");
  await queue.waitForIdle();
  scheduler.runAll();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:ls\r"]);
});

test("debounces printable input when no mapped key arrives", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "pwd");
  await queue.waitForIdle();
  expect(calls).toEqual([]);

  scheduler.runAll();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:pwd"]);
});

test("preserves order across buffered text and multiple mapped keys", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "echo hi");
  queue.sendMappedKey(targetA, "enter");
  queue.sendMappedKey(targetA, "up");
  await queue.waitForIdle();
  scheduler.runAll();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:echo hi\r", "key:surface-a:up"]);
});

test("keeps buffered text targeted to the surface that produced it", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "danger");
  scheduler.runAll();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:danger"]);
});

test("flushes old target buffer before collecting text for a new target", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "pwd");
  queue.appendText(targetB, "ls");
  scheduler.runAll();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:pwd", "text:surface-b:ls"]);
});

test("flushes buffered text before a mapped key for another target", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "ls");
  queue.sendMappedKey(targetB, "enter");
  scheduler.runAll();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:ls", "text:surface-b:\r"]);
});

test("sends bare enter as carriage return text", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.sendEnter(targetA);
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:\r"]);
});

test("combines buffered input and enter atomically for the original target", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "echo hi");
  queue.sendEnter(targetA);
  scheduler.runAll();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:echo hi\r"]);
});

test("flushes another target before sending enter to the requested target", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "pwd");
  queue.sendEnter(targetB);
  scheduler.runAll();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:pwd", "text:surface-b:\r"]);
});

test("dispose cancels queued mutations that have not started", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  let releaseFirstMutation: (() => void) | null = null;
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
      if (text === "first") {
        await new Promise<void>((resolve) => {
          releaseFirstMutation = resolve;
        });
      }
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "first");
  queue.flushBuffer();
  queue.sendMappedKey(targetA, "enter");
  await Promise.resolve();

  queue.dispose();
  releaseFirstMutation?.();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:first"]);
});

test("dispose prevents stale afterMutation callbacks", async () => {
  const calls: string[] = [];
  const scheduler = new ManualScheduler();
  let releaseFirstMutation: (() => void) | null = null;
  const queue = new TerminalInputQueue({
    scheduler,
    targetEquals,
    sendText: async (target, text) => {
      calls.push(`text:${target.surfaceID}:${text}`);
      await new Promise<void>((resolve) => {
        releaseFirstMutation = resolve;
      });
    },
    sendKey: async (target, key) => {
      calls.push(`key:${target.surfaceID}:${key}`);
    },
    afterMutation: async (target) => {
      calls.push(`after:${target.surfaceID}`);
    },
    handleError: (error) => {
      throw error;
    },
  });

  queue.appendText(targetA, "first");
  queue.flushBuffer();
  await Promise.resolve();

  queue.dispose();
  releaseFirstMutation?.();
  await queue.waitForIdle();

  expect(calls).toEqual(["text:surface-a:first"]);
});
