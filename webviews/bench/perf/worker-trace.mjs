// Bench helper: logs every highlight-worker request and reply (type, file, line counts, time),
// to see what the workers do before the viewport is highlighted.
import { chromium } from "playwright";
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
await page.addInitScript(() => {
  const log = (window.__workerLog = []);
  const Original = window.Worker;
  let next = 0;
  window.Worker = class extends Original {
    constructor(...args) {
      super(...args);
      const index = next++;
      const post = this.postMessage.bind(this);
      this.postMessage = (message, ...rest) => {
        const diff = message?.diff;
        log.push([
          Math.round(performance.now()),
          index,
          "send",
          message?.type,
          diff?.name ?? message?.file?.name ?? "",
          diff ? (diff.additionLines?.length ?? 0) + (diff.deletionLines?.length ?? 0) : 0,
          (message?.resolvedLanguages ?? []).map((l) => l.name).join(","),
        ]);
        return post(message, ...rest);
      };
      this.addEventListener("message", (event) =>
        log.push([Math.round(performance.now()), index, "recv", event.data?.requestType ?? event.data?.type]),
      );
    }
  };
});
await page.goto(process.argv[2]);
await page.waitForTimeout(Number(process.argv[3] ?? 9000));
for (const row of await page.evaluate(() => window.__workerLog)) console.log(JSON.stringify(row));
await browser.close();
