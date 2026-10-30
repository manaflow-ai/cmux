import { describe, expect, test } from "bun:test";
import { RoomMemory, type MemoryNode } from "../src/memory.ts";

const long = (label: string) => `${label} ${"words ".repeat(60)}`;

function memoryWith(summaries: Array<[MemoryNode, MemoryNode]>, keepRecent = 2) {
  return new RoomMemory({
    keepRecent,
    freeBytes: 512,
    summarize: async (left, right) => {
      summaries.push([left, right]);
      return `sum(${left.start}+${left.n},${right.start}+${right.n})`;
    },
  });
}

describe("RoomMemory", () => {
  test("keeps the newest entries verbatim and folds older pairs into one binary tree", async () => {
    const calls: Array<[MemoryNode, MemoryNode]> = [];
    const memory = memoryWith(calls);
    for (let i = 1; i <= 6; i += 1) memory.append("speech", "ana", long(`line ${i}`));
    await memory.settle();
    const view = memory.view();
    // Entries 1-4 fold to one level-2 node; 5 and 6 stay raw.
    expect(view.map((node) => [node.start, node.n, node.level])).toEqual([
      [1, 4, 2],
      [5, 1, 0],
      [6, 1, 0],
    ]);
    // Two short summaries fit 512 bytes, so the top merge is free.
    expect(view[0]!.text).toBe("sum(1+1,2+1)\nsum(3+1,4+1)");
    expect(memory.render().split("\n")[1]).toStartWith("5+1|ana: line 5");
    expect(calls.length).toBe(2);
  });

  test("merges small pairs for free, with no model call", async () => {
    const calls: Array<[MemoryNode, MemoryNode]> = [];
    const memory = memoryWith(calls);
    for (const text of ["hi", "hello", "ok", "sure"]) memory.append("speech", "bo", text);
    await memory.settle();
    expect(calls.length).toBe(0);
    expect(memory.view()[0]).toEqual({ start: 1, n: 2, level: 1, text: "bo: hi\nbo: hello" });
  });

  test("the log stays verbatim and is persisted in order", () => {
    const saved: number[] = [];
    const memory = new RoomMemory({ summarize: async () => "", persist: (entry) => saved.push(entry.id) });
    memory.append("speech", "a", "one");
    memory.append("screen", "a", "Xcode: build failed");
    expect(saved).toEqual([1, 2]);
    expect(memory.since(1).map((entry) => entry.text)).toEqual(["Xcode: build failed"]);
    expect(memory.render()).toBe("1+1|a: one\n2+1|screen (a): Xcode: build failed");
  });

  test("retention drops old entries and the summaries over them", async () => {
    const memory = memoryWith([], 1);
    memory.append("speech", "a", long("old 1"), 1000);
    memory.append("speech", "a", long("old 2"), 2000);
    memory.append("speech", "a", long("new"), 9000);
    await memory.settle();
    expect(memory.view()[0]!.n).toBe(2);
    expect(memory.prune(5000)).toBe(2);
    expect(memory.view().map((node) => node.start)).toEqual([3]);
  });

  test("reattribute credits a line to its real speaker", () => {
    const memory = new RoomMemory({ summarize: async () => "" });
    const entry = memory.append("speech", "far mic", "ship it");
    memory.reattribute(entry.id, "near mic");
    expect(memory.render()).toBe("1+1|near mic: ship it");
  });
});
