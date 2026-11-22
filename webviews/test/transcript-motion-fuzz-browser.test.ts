// cmux-web-test-timeout: 900
// The transcript motion detector (support/transcriptMotion.ts) over the fold fuzzer's seeded chats
// (browser/fold-fuzz.scenario.ts), as a gate. Leo, 2026-11-22: "IT JUMPS ... DON'T JUMP / FIX THE
// ANIMATIONS / FIX THE LOGIC ... AND I SHOULDN'T HAVE TO KEEP IDENTIFYING THIS / MATHEMATICALLY, ALL OF
// THESE SHOULD BE FLAGGABLE".
//
// Each seed plays through the fold recorder's page at real speed with the shipped fold look; every
// element's box is read every frame. A seed fails when the detector flags a family (a jump: `move`, `scroll-step` or `resize`; or
// `off-curve`) that transcript-motion-baseline.json does not list for it, in two plays out of two (a play
// is real time on a shared runner: a flag must repeat to count). The baseline lists the seeds that flag
// today; it only shrinks: a listed seed that plays clean is printed so it comes out. Regenerate it from
// the full run: `bun scripts/fold-fuzz.ts --seeds 500 --look wipe --jobs 6 --out DIR --baseline
// test/transcript-motion-baseline.json`.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Counts = { move: number; "scroll-step": number; resize: number; "off-curve": number };
/** `flagged`: each seed's counts, the most of each kind over `plays` full runs. */
type Baseline = { look: string; seeds: number; plays?: number; flagged: Record<string, Counts> };

await requireBrowserLane("transcript-motion-fuzz-browser.test.ts", async () => {
  setDefaultTimeout(880_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-motion-fuzz-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript motion fuzz", () => test("chromium", () => {}));
    return;
  }
  const { openRecorder } = await import("../scripts/fold-variants-record");
  const { fuzz, seedFlags, detectorTable } = await import("../scripts/fold-fuzz");
  const baseline = (await Bun.file(path.join(import.meta.dir, "transcript-motion-baseline.json")).json()) as Baseline;
  /// The seeds CI plays: the baseline's first `CMUX_MOTION_FUZZ_SEEDS` (default 60; the full 500 is the report's run).
  const count = Number(process.env.CMUX_MOTION_FUZZ_SEEDS ?? 60);
  const seeds = Array.from({ length: Math.min(count, baseline.seeds) }, (_, i) => i + 1);
  let recorder: Awaited<ReturnType<typeof openRecorder>>;
  beforeAll(async () => {
    recorder = await openRecorder();
  });
  afterAll(async () => {
    await recorder?.close();
  });

  /// The ratchet's unit: a seed that jumped (any move, scroll step or resize) or played an animation off the
  /// curve. Which of the three jumps a frame lands in varies with a shared runner's frame timing (a row that
  /// rode a snap one play moves by a pixel more the next), so a seed that already jumps may jump another way;
  /// a seed that never jumped may not start.
  const FAMILIES = {
    jump: (c: Partial<Counts> = {}) => (c.move ?? 0) + (c["scroll-step"] ?? 0) + (c.resize ?? 0),
    "off-curve": (c: Partial<Counts> = {}) => c["off-curve"] ?? 0,
  } as const;
  /** Each seed's families that the baseline does not list for it. */
  const fresh = (flags: Record<string, Counts>) =>
    Object.entries(flags)
      .map(([seed, counts]) => ({
        seed: Number(seed),
        kinds: (Object.keys(FAMILIES) as (keyof typeof FAMILIES)[]).filter(
          (family) => FAMILIES[family](counts) > 0 && !FAMILIES[family](baseline.flagged[seed]),
        ),
        counts,
      }))
      .filter((entry) => entry.kinds.length > 0);

  test(`no seed flags a kind the baseline does not list (${seeds.length} seeds, look ${baseline.look})`, async () => {
    const results = await fuzz(recorder.browser, recorder.port, [baseline.look], seeds, 4);
    console.log(detectorTable(results, [baseline.look]).join("\n"));
    const flags = seedFlags(results, baseline.look);
    const cleared = seeds.filter((seed) => baseline.flagged[seed] && !flags[seed]);
    if (cleared.length)
      console.log(`transcript-motion: seeds now clean, take them out of the baseline: ${cleared.join(", ")}`);
    const suspects = fresh(flags);
    // Played again, one at a time: a flag counts only when it repeats.
    const again = suspects.length
      ? seedFlags(
          await fuzz(
            recorder.browser,
            recorder.port,
            [baseline.look],
            suspects.map((s) => s.seed),
            1,
          ),
          baseline.look,
        )
      : {};
    const confirmed = fresh(again).filter((entry) => suspects.some((s) => s.seed === entry.seed));
    for (const entry of confirmed) {
      const first = results.find((r) => r.seed === entry.seed);
      const verdict = first && "motion" in first.numbers ? first.numbers.motion : undefined;
      console.log(
        `transcript-motion: seed ${entry.seed} flags ${entry.kinds.join(", ")} (${JSON.stringify(entry.counts)}); ` +
          `replay: bun scripts/fold-fuzz.ts --only ${entry.seed} --look ${baseline.look}; first flags: ` +
          JSON.stringify(verdict?.first ?? []),
      );
    }
    expect(confirmed.map((entry) => `${entry.seed}: ${entry.kinds.join(", ")}`)).toEqual([]);
  });
});
