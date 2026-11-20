// Live proof for the Labs pairing slice: real page, mock host, trusted browser clicks.
// Run with cmux-ci test --setup playwright --not-tests --artifact DIR --
//   node webviews/scripts/pages/mobile-pairing-revoke-look.mjs
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = fileURLToPath(new URL("../..", import.meta.url));
const out = process.env.FAST_CHECKS_OUT;
if (!out) throw new Error("FAST_CHECKS_OUT is required");
fs.mkdirSync(out, { recursive: true });
const server = spawn("bun", ["run", "dev:pages", "--host", "127.0.0.1", "--strictPort"], {
  cwd: root,
  // Own the bun launcher and its Vite child so cleanup closes inherited output pipes too.
  detached: true,
  env: { ...process.env, CMUX_PAGES_DEV_PORT: "4297" },
  stdio: ["ignore", "pipe", "pipe"],
});
let browser;
try {
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("preview did not start in 60s")), 60000);
    for (const pipe of [server.stdout, server.stderr])
      pipe.on("data", (chunk) => {
        process.stdout.write(chunk);
        if (String(chunk).includes("4297")) {
          clearTimeout(timeout);
          resolve();
        }
      });
    server.on("exit", (code) => {
      clearTimeout(timeout);
      reject(new Error(`preview exited ${code}`));
    });
  });
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 720, height: 900 }, recordVideo: { dir: out } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.goto("http://127.0.0.1:4297/mobile-pairing/?mock");
  await page.getByRole("button", { name: "Sign In", exact: true }).click();
  await page.locator('[data-action="allow"]').click();
  await page.locator(".pairing-phones").waitFor();
  if (await page.getByRole("button", { name: "Revoke", exact: true }).count())
    throw new Error("default exposes revoke");
  await page.screenshot({ path: path.join(out, "default-off.png"), fullPage: true });
  await page.goto("http://127.0.0.1:4297/mobile-pairing/?mock=revoke");
  await page.getByRole("button", { name: "Sign In", exact: true }).click();
  await page.locator('[data-action="allow"]').click();
  await page.locator('[data-phone="phone-offline"]').waitFor();
  await page.screenshot({ path: path.join(out, "approved.png"), fullPage: true });
  await page.locator('[data-phone="phone-1"] button').click();
  await page.locator('[data-phone="phone-1"]').waitFor({ state: "detached" });
  await page.locator('[data-phone="phone-offline"]').waitFor();
  await page.screenshot({ path: path.join(out, "one-revoked.png"), fullPage: true });
  await page.locator('[data-phone="phone-offline"] button').click();
  await page.getByText("No phones approved on this Mac.", { exact: true }).waitFor();
  await page.screenshot({ path: path.join(out, "empty.png"), fullPage: true });
  await page.setViewportSize({ width: 320, height: 740 });
  await page.screenshot({ path: path.join(out, "empty-narrow.png"), fullPage: true });
  if (errors.length) throw new Error(errors.join("\n"));
  fs.writeFileSync(
    path.join(out, "flow.json"),
    JSON.stringify({ defaultOff: true, selectedPhoneOnly: true, empty: true, errors }, null, 2),
  );
  await context.close();
  console.log("LIVE_FLOW_COMPLETE: default off → Labs mock → revoke one → other stays → empty");
} finally {
  await browser?.close();
  if (server.pid) {
    try {
      process.kill(-server.pid, "SIGTERM");
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
}
console.log("LIVE_CAPTURE_CLEANUP_COMPLETE");
