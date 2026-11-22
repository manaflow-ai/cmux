#!/usr/bin/env bun
/**
 * Measure the deterministic composer side of on-device dictation.
 *
 * Run from the cmux checkout with:
 *   bun scripts/measure/on-device-voice-input.ts
 *
 * This deliberately does not claim speech-recognizer latency or word-error
 * rate. Apple Speech APIs require a macOS device and a recorded-utterance
 * fixture. The benchmark measures prompt merge cost and fixture preservation.
 */
import { anchorAt, applyDictation } from "../../webviews/src/agent-session/acpmux/dictationText.ts";

type Prompt = { value: string; selectionStart: number; selectionEnd: number };
type Anchor = ReturnType<typeof anchorAt> | null;

const update = (state: "listening" | "finalizing", text: string) => ({
  state,
  text,
  cancelled: false,
});

function run(prompt: Prompt, texts: string[]): Prompt {
  let current = prompt;
  let anchor: Anchor = null;
  for (let index = 0; index < texts.length; index += 1) {
    const result = applyDictation(
      current,
      anchor,
      update(index === texts.length - 1 ? "finalizing" : "listening", texts[index]!),
    );
    if (result) {
      current = {
        value: result.value,
        selectionStart: result.selectionStart,
        selectionEnd: result.selectionEnd,
      };
      anchor = result.anchor;
    }
  }
  return current;
}

function percentile(values: number[], percent: number): number {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.floor((percent / 100) * sorted.length))]!;
}

function benchmark(rounds: number, words: string[]) {
  const updates = words.map((_, index) => words.slice(0, index + 1).join(" "));
  for (let index = 0; index < 2_000; index += 1) {
    run({ value: "", selectionStart: 0, selectionEnd: 0 }, updates);
  }
  const times: number[] = [];
  for (let index = 0; index < rounds; index += 1) {
    const started = performance.now();
    run({ value: "", selectionStart: 0, selectionEnd: 0 }, updates);
    times.push(performance.now() - started);
  }
  return {
    rounds,
    updates: words.length,
    p50_ms: percentile(times, 50),
    p95_ms: percentile(times, 95),
    p99_ms: percentile(times, 99),
    max_ms: Math.max(...times),
  };
}

const fixtures: Array<[string, string[], string]> = [
  ["empty", ["hello", "hello world"], "hello world"],
  ["punctuation", ["ship", "ship it."], "ship it."],
  ["existing prefix", ["send report"], "Draft: send report"],
  ["existing suffix", ["please continue"], "please continue today"],
  ["revision", ["ice", "ice cream"], "ice cream"],
  ["unicode", ["你好", "你好世界"], "你好世界"],
  ["empty final", [""], ""],
];

const fixtureResults = fixtures.map(([name, texts, expected]) => {
  const prompt =
    name === "existing prefix"
      ? { value: "Draft: ", selectionStart: 7, selectionEnd: 7 }
      : name === "existing suffix"
        ? { value: " today", selectionStart: 0, selectionEnd: 0 }
        : { value: "", selectionStart: 0, selectionEnd: 0 };
  const actual = run(prompt, texts).value;
  return { name, expected, actual, pass: actual === expected };
});

console.log(
  JSON.stringify(
    {
      fixtures: fixtureResults,
      fixture_passes: fixtureResults.filter((fixture) => fixture.pass).length,
      fixture_count: fixtureResults.length,
      short: benchmark(10_000, "voice input to the composer should keep partial text stable".split(" ")),
      long: benchmark(2_000, Array.from({ length: 64 }, (_, index) => `word${index}`)),
    },
    null,
    2,
  ),
);
