import { expect, test } from "bun:test";
import {
  createThrottledEmitter,
  mobileDiffStatsMessage,
  sameCurrentFileMessage,
  type MobileDiffCurrentFileMessage,
} from "../src/mobile-diff";
import type { DiffItem } from "../src/diff-stream";

test("mobile stats map Pierre file metadata into the native contract", () => {
  const items = [
    item("Sources/New.swift", "rename-changed", 4, 2, {
      prevName: "Sources/Old.swift",
    }),
    item("Assets/icon.bin", "new", 0, 0, { cmuxBinary: true }),
    item("README.md", "modified", 1, 3),
  ];

  expect(mobileDiffStatsMessage(items)).toEqual({
    type: "stats",
    files: [
      {
        path: "Sources/New.swift",
        oldPath: "Sources/Old.swift",
        status: "renamed",
        additions: 4,
        deletions: 2,
      },
      {
        path: "Assets/icon.bin",
        status: "added",
        additions: 0,
        deletions: 0,
        binary: true,
      },
      {
        path: "README.md",
        status: "modified",
        additions: 1,
        deletions: 3,
      },
    ],
    totalAdditions: 5,
    totalDeletions: 5,
  });
});

test("current-file reporting emits immediately and coalesces a fast flick to four updates per second", () => {
  let now = 0;
  let nextTimer = 1;
  const timers = new Map<number, { callback: () => void; due: number }>();
  const emitted: MobileDiffCurrentFileMessage[] = [];
  const clock = {
    clearTimeout(id: ReturnType<typeof setTimeout>) {
      timers.delete(id as unknown as number);
    },
    now: () => now,
    setTimeout(callback: () => void, delay: number) {
      const id = nextTimer++;
      timers.set(id, { callback, due: now + delay });
      return id as unknown as ReturnType<typeof setTimeout>;
    },
  };
  const reporter = createThrottledEmitter(
    (message: MobileDiffCurrentFileMessage) => emitted.push(message),
    250,
    sameCurrentFileMessage,
    clock,
  );
  const message = (path: string, index: number): MobileDiffCurrentFileMessage => ({
    type: "currentFile",
    path,
    index,
    total: 4,
  });

  reporter.push(message("one", 0));
  advance(50);
  reporter.push(message("two", 1));
  advance(50);
  reporter.push(message("three", 2));
  advance(149);
  expect(emitted.map((event) => event.path)).toEqual(["one"]);
  advance(1);
  expect(emitted.map((event) => event.path)).toEqual(["one", "three"]);

  reporter.push(message("four", 3));
  advance(100);
  reporter.push(message("three", 2));
  advance(150);
  expect(emitted.map((event) => event.path)).toEqual(["one", "three"]);
  reporter.dispose();

  function advance(milliseconds: number) {
    now += milliseconds;
    while (true) {
      const due = Array.from(timers.entries())
        .filter(([, timer]) => timer.due <= now)
        .sort((left, right) => left[1].due - right[1].due)[0];
      if (!due) {
        return;
      }
      timers.delete(due[0]);
      due[1].callback();
    }
  }
});

function item(
  name: string,
  type: string,
  additions: number,
  deletions: number,
  metadata: Record<string, unknown> = {},
): DiffItem {
  return {
    id: name,
    type: "diff",
    fileDiff: {
      name,
      type,
      hunks: [{ additionLines: additions, deletionLines: deletions }],
      ...metadata,
    },
  } as DiffItem;
}
