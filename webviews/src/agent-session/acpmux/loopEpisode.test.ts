import { expect, test } from "bun:test";
import { readLoopEpisode, stuckAttention } from "./loopEpisode";

const episode = { episodeId: 1, since: 123, count: 3, diagnosis: "Repeated failure", hint: "Try another approach" };

test("attention follows a running turn and clears on progress, stop, close, or turn end", () => {
  const running = { status: "running", state: "running", turn: { stalledSince: 123 }, loopEpisode: episode };
  expect(stuckAttention(running)).toEqual({ loopEpisode: episode, stalledSince: 123 });
  expect(running.state).toBe("running");
  for (const summary of [
    { ...running, turn: {}, loopEpisode: null },
    { ...running, turn: null },
    { ...running, state: "stopping" },
    { ...running, status: "closed" },
    { status: "running", turn: {} },
  ]) {
    expect(stuckAttention(summary)).toEqual({ loopEpisode: undefined, stalledSince: undefined });
  }
});

test("old or malformed daemon attention cannot produce stale UI", () => {
  for (const value of [
    undefined,
    null,
    {},
    { ...episode, episodeId: 0 },
    { ...episode, count: 1.5 },
    { ...episode, since: Infinity },
    { ...episode, diagnosis: "x".repeat(1025) },
    { ...episode, hint: "x".repeat(2049) },
  ])
    expect(readLoopEpisode(value)).toBeUndefined();
  for (const stalledSince of [undefined, null, "123", NaN, Infinity, -1]) {
    expect(stuckAttention({ status: "running", turn: { stalledSince } }).stalledSince).toBeUndefined();
  }
});
