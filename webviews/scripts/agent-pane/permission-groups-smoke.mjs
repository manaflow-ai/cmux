// Exercise the docked permission UI with the deterministic browser fixture.
// This is presentation evidence; daemon integration fixtures verify actual ACP responses.
import path from "node:path";
import fs from "node:fs/promises";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const out = path.resolve(process.argv[2] ?? path.join(webviews, "dist/permission-groups-smoke"));
await fs.mkdir(out, { recursive: true });
const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-preview.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
});
await server.listen();
let browser;
try {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    args: ["--no-sandbox"],
  });
  const page = await browser.newPage({ viewport: { width: 1260, height: 900 }, deviceScaleFactor: 2 });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const { port } = server.httpServer.address();
  const url = `http://127.0.0.1:${port}/?fixture=grouped-permissions`;
  await page.goto(url);
  const panel = page.getByRole("region", { name: "Tool permissions" });
  // A section with an accessible name has region semantics.
  await panel.getByRole("button", { name: "Allow once", exact: true }).waitFor();
  await page.evaluate(() =>
    window.cmuxAcpmuxBridge?.applyShortcuts?.({
      "agentPane.permission.allowOnce": "⌥⌘1",
      "agentPane.permission.allowChat": "⌥⌘2",
      "agentPane.permission.deny": "⌥⌘3",
      "agentPane.permission.expand": "⌥⌘4",
    }),
  );
  await expectText(panel, "Allow once (⌥⌘1)");
  assert.equal(await panel.getByRole("button").count(), 4);
  await page.locator(".acpmux-shell").screenshot({ path: path.join(out, "grouped-dark.png") });
  await panel.locator("summary").filter({ hasText: "Run project tests" }).click();
  assert.match(await panel.locator("details[open] pre").innerText(), /bun test/);
  await page.locator(".acpmux-shell").screenshot({ path: path.join(out, "grouped-expanded.png") });
  await panel.getByRole("button", { name: /Allow for this chat/ }).click();
  await panel.getByRole("button", { name: /Revoke/ }).waitFor();
  assert.match(await panel.innerText(), /Future eligible tool requests are allowed/);
  assert.equal(await panel.getByRole("button", { name: "Allow once", exact: true }).count(), 0);
  await page.locator(".acpmux-shell").screenshot({ path: path.join(out, "chat-allowance.png") });
  await panel.getByRole("button", { name: /Revoke/ }).click();
  await page.waitForFunction(() => !document.querySelector(".acpmux-permission-allowance"));
  await page.goto(url);
  await page.getByRole("button", { name: "Toggle light" }).click();
  await page.setViewportSize({ width: 760, height: 900 });
  await panel.getByRole("button", { name: /Deny/ }).waitFor();
  await page.locator(".acpmux-shell").screenshot({ path: path.join(out, "grouped-light-narrow.png") });
  await panel.getByRole("button", { name: /Deny/ }).click();
  await page.waitForFunction(() => !!document.querySelector(".acpmux-permission-receipt"));
  assert.equal(await panel.getByRole("button").count(), 0);
  assert.deepEqual(errors, []);
  console.log("Grouped permissions browser fixture: expand, allow chat, revoke, deny and narrow layout passed.");
  console.log(out);
} finally {
  await browser?.close();
  await server.close();
}

async function expectText(locator, text) {
  await locator.getByText(text, { exact: true }).waitFor();
}
