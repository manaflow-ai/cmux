// l10n-allow-file: benchmark output, not shipped UI.
// Script time per frame while a reply streams, and how often its closed Markdown blocks draw again
// (cmuxterm-hq docs/design/agent-transcript-clean-slate.md step 3: "p95 script time per frame under
// 4 ms while streaming; 0 re-renders of closed blocks"). The page is test/browser/streaming-text.html,
// the one streaming-text-frames.test.ts drives (the real transcript, a 5,000-character Markdown reply
// at Claude's and Codex's cadence), served as a production build (bench/support/benchPage.ts), so
// React runs as it ships. Each round is a fresh page; the row is the median over rounds.
//   streaming_text.<cadence>.script_p95_ms       p95 of each streaming frame's script (streaming-text.clock.ts)
//   streaming_text.<cadence>.work_p95_ms         the same with the layout each frame forced
//   streaming_text.<cadence>.closed_rerenders    committed renders of a closed block after its first
//   bun bench/streaming-text-frames.bench.ts [--rounds 3] [--cadences claude,codex] [--dev]
/// <reference types="bun" />
import { chromium } from "./browsers";
import type { StreamReport } from "../test/browser/streaming-text.harness";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const ROUNDS = Number(flag("--rounds") ?? 3);
const CADENCES = (flag("--cadences") ?? "claude,codex").split(",");

const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)] ?? 0;
};

const served = await serveBenchPage("/test/browser/streaming-text.html");
const browser = await chromium.launch({ headless: true });
try {
  const label = served.dev ? " (dev)" : "";
  for (const cadence of CADENCES) {
    const reports: StreamReport[] = [];
    for (let round = 0; round < ROUNDS; round += 1) {
      const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
      await page.addInitScript(() => {
        const scope = globalThis as { cmuxExperiments?: Record<string, string> };
        scope.cmuxExperiments = { ...scope.cmuxExperiments, "follow-motion": "blocks" };
      });
      await gotoBenchPage(page, served);
      await page.waitForFunction(() => "__streamingText" in window, null, { timeout: 60_000 });
      await page.getByText("History answer 6.").waitFor();
      await page.waitForFunction(
        () => document.fonts.status === "loaded" && (document.querySelector(".acpmux-scroll")?.scrollHeight ?? 0) > 0,
      );
      const report = (await page.evaluate(
        (cadence) =>
          (
            window as unknown as { __streamingText: { run(o: { cadence: string }): Promise<unknown> } }
          ).__streamingText.run({ cadence }),
        cadence,
      )) as StreamReport;
      await page.close();
      reports.push(report);
      console.log(
        `round ${round + 1} ${cadence}: script p95 ${report.work.scriptMs.p95} ms, work p95 ${report.work.totalMs.p95} ms, ` +
          `closed ${report.markdown.closed}, rerenders ${report.markdown.rerenders}, frames ${report.work.frames}`,
      );
    }
    const rows = {
      script_p95_ms: median(reports.map((r) => r.work.scriptMs.p95)),
      work_p95_ms: median(reports.map((r) => r.work.totalMs.p95)),
      closed_rerenders: median(reports.map((r) => r.markdown.rerenders)),
    };
    for (const [name, value] of Object.entries(rows)) console.log(`streaming_text.${cadence}.${name}${label} ${value}`);
  }
} finally {
  await browser.close();
  await served.close();
}
