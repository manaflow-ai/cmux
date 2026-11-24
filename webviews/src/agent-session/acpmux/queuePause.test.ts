// The queue's Resume (queuePause.ts resumeQueue): the paused note's button and the status dot's
// `resumeQueue` action make the same call, on acpmux's first prompt.
import { expect, test } from "bun:test";
import type { QueueEdit } from "./model";
import { resumeQueue } from "./queuePause";

const recorder = () => {
  const calls: [string, QueueEdit][] = [];
  const change = (id: string, edit: QueueEdit) => {
    calls.push([id, edit]);
    return Promise.resolve(true);
  };
  return { calls, change };
};

test("resume goes to acpmux's first prompt, past one the folder's trust holds", () => {
  const { calls, change } = recorder();
  expect(resumeQueue([{ id: "held", held: true }, { id: "a" }, { id: "b" }], change)).toBe(true);
  expect(calls).toEqual([["a", { op: "resume" }]]);
});

test("a queue of held prompts resumes its first; an empty one does nothing", () => {
  const { calls, change } = recorder();
  expect(resumeQueue([{ id: "only", held: true }], change)).toBe(true);
  expect(resumeQueue([], change)).toBe(false);
  expect(calls).toEqual([["only", { op: "resume" }]]);
});

test("a refused resume is swallowed, as the note's button did", async () => {
  expect(resumeQueue([{ id: "a" }], () => Promise.reject(new Error("refused")))).toBe(true);
  await Promise.resolve();
});
