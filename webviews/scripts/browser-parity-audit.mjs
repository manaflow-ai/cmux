// Diagnostic only: real Chromium, development host, no native bridge or device credential.
// A captured page is NOT proof that its backend operations work. No CI gate is installed.
import fs from "node:fs/promises";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { launchBrowser, startDevServer, webviews } from "./agent-pane/mockLaunch.mjs";

if (!process.env.FAST_CHECKS_OUT) throw new Error("Run through cmux-ci with FAST_CHECKS_OUT for the audit artifacts");
const out = path.resolve(process.env.FAST_CHECKS_OUT);
// The shared Vite launcher resolves its document root from the current directory.
process.chdir(webviews);
await fs.mkdir(out, { recursive: true });
const head = execFileSync("git", ["rev-parse", "HEAD"], { cwd: webviews, encoding: "utf8" }).trim();
const pages = (await fs.readdir(path.join(webviews, "src/pages"))).sort((left, right) => left.localeCompare(right));
const entries = [];
for (const name of pages) {
  try {
    await fs.access(path.join(webviews, "src/pages", name, "main.tsx"));
    entries.push(name);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}
const report = {
  schema: "cmux.browser-parity-audit.v1",
  head,
  observedAt: new Date().toISOString(),
  environment: "development server; no native bridge; no device credential; no mock injection",
  meaning: "Capture receipt only. Rendered pages may use fallback mocks. Not a parity verdict.",
  pageEntries: entries,
  observations: [],
};
const server = await startDevServer("vite.config.ts");
try {
  const browser = await launchBrowser();
  try {
    report.browser = browser.version();
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    try {
      for (const route of ["settings", "files", "history", "agent-pane"]) {
        const page = await context.newPage();
        const errors = [];
        page.on("pageerror", (error) => errors.push(error.message));
        const observation = { route: `/${route}/`, errors, screenshot: `${route}.png` };
        report.observations.push(observation);
        try {
          const response = await page.goto(new URL(`${route}/`, server.url).href, {
            waitUntil: "load",
            timeout: 60_000,
          });
          observation.httpStatus = response?.status();
          await page.waitForFunction(
            () => (document.querySelector("#root")?.textContent?.trim().length ?? 0) > 0,
            undefined,
            { timeout: 30_000 },
          );
          observation.state = await page.evaluate(() => ({
            title: document.title,
            nativePageBridge: Boolean(window.webkit?.messageHandlers?.cmuxPage),
            body: document.body.innerText.slice(0, 6000),
            buttons: [...document.querySelectorAll("button")]
              .map((button) => button.getAttribute("aria-label") || button.innerText)
              .filter(Boolean)
              .slice(0, 60),
          }));
          if (route === "settings") {
            observation.developmentActionReplies = await page.evaluate(async () => {
              const { devHostReply } = await import("/src/dev-host/host.ts");
              const host = { endpoint: "ws://127.0.0.1:1", token: "audit-unused" };
              const replies = [];
              for (const method of ["tab.open", "tab.jump", "action.run", "dictation.start"]) {
                replies.push({ method, reply: await devHostReply(host, { id: "audit", method, params: {} }) });
              }
              return replies;
            });
          }
        } catch (error) {
          observation.captureError = String(error);
        }
        await page.screenshot({ path: path.join(out, observation.screenshot) });
        await page.close();
      }
    } finally {
      await context.close();
    }
  } finally {
    await browser.close();
  }
} finally {
  await fs.writeFile(path.join(out, "browser-parity-audit.json"), `${JSON.stringify(report, null, 2)}\n`);
  await server.close();
}
console.log(
  JSON.stringify({
    head,
    artifact: "browser-parity-audit.json",
    captured: report.observations.length,
    verdict: "observations-only",
  }),
);
