// Manual live-preview proof; run on the fleet before the test suites. No CI gate.
// From the repo: cmux-ci test --setup playwright --not-tests --artifact .cmux-scratch/provider-rehearsal-proof -- 'cd webviews && node scripts/provider-rehearsal-proof.mjs'
import fs from "node:fs/promises";
import path from "node:path";
import { createServer } from "vite-plus";
import { chromium } from "playwright";

const out = path.resolve(process.env.FAST_CHECKS_OUT || "../.cmux-scratch/provider-rehearsal-proof");
await fs.mkdir(out, { recursive: true });
const server = await createServer({
  configFile: "vite.config.pages-dev.ts",
  server: { host: "127.0.0.1", port: 4297, strictPort: true, watch: null },
});
let browser;
const evidence = { simulated: true, nativeHostVerified: false, steps: [], errors: [] };
try {
  await server.listen();
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1000, height: 780 }, recordVideo: { dir: out } });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on("pageerror", (error) => evidence.errors.push(error.message));
  const capture = async (name) => {
    await page.screenshot({ path: path.join(out, `${name}.png`), fullPage: true });
    evidence.steps.push(name);
  };
  await page.goto("http://127.0.0.1:4297/cloud/?mock=all");
  await page.getByRole("heading", { name: "Cloud", exact: true }).waitFor();
  if (await page.getByText("Provider rehearsal", { exact: true }).count())
    throw new Error("Experiment visible by default");
  await capture("01-default-off");
  await page.evaluate(() =>
    localStorage.setItem("cmux.experiments", JSON.stringify({ "cloud-provider-rehearsal": "collapsed" })),
  );
  await page.reload();
  await page.getByText("Provider rehearsal", { exact: true }).waitFor();
  await capture("02-collapsed");
  await page.getByText("Provider rehearsal", { exact: true }).click();
  for (const [index, label, state] of [
    [3, "Run lifecycle", "deleted"],
    [4, "Fail enrollment", "deleted"],
    [5, "Fail cleanup", "orphaned"],
  ]) {
    await page.getByRole("button", { name: label, exact: true }).click();
    await page.locator(".cloud-provider-rehearsal pre").waitFor();
    const result = JSON.parse(await page.locator(".cloud-provider-rehearsal pre").innerText());
    if (result.simulated !== true || result.receipts.at(-1).state !== state)
      throw new Error(`Unexpected ${label} result`);
    if (result.receipts.at(-1).replayed !== true) throw new Error(`Missing same-key replay: ${label}`);
    evidence[label] = result;
    await capture(`0${index}-${result.scenario}`);
  }
  await page.evaluate(() =>
    localStorage.setItem("cmux.experiments", JSON.stringify({ "cloud-provider-rehearsal": "expanded" })),
  );
  await page.reload();
  await page.getByRole("button", { name: "Run lifecycle", exact: true }).waitFor();
  await page.setViewportSize({ width: 560, height: 780 });
  await capture("06-expanded-narrow");
  await context.close();
  if (evidence.errors.length) throw new Error(evidence.errors.join("\n"));
  console.log(JSON.stringify({ status: "passed", out, steps: evidence.steps }));
} finally {
  await fs.writeFile(path.join(out, "receipt.json"), `${JSON.stringify(evidence, null, 2)}\n`);
  await browser?.close();
  await server.close();
}
