// The host redacts sensitive field values in frame.observe results (browser
// lead's final rule, 2026-10-04): a password field, or one whose
// autocomplete names one-time-code, current-password, new-password or a cc-
// token, reads as "********" (or "" when empty), and its value appears as
// "********" wherever an observe result (snapshot, read, describe,
// strictError) would show it. Other fields read as they are.
//
//   node --test tests/browser-parity/unit/observe-redaction.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime, createDevBrowser, createNodeHost, createHostedRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { makeTestDir, removeTestDir, removeTestDirIfEmpty } from "../lib/test-dirs.mjs";

const ns = loadRuntime();

test("observe results never show a sensitive field's value", async () => {
  const servers = await startFixtureServers();
  const browser = await createDevBrowser();
  const driver = browser.driver();
  const dir = makeTestDir("observe-redaction-");
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId: `redaction-${process.pid}`, print: (level, text) => lines.push(text) });
  const hosted = createHostedRepl(ns, { host, driver });
  try {
    const r = await hosted.repl.evaluate(`
      await page.goto(${JSON.stringify(servers.origins.primary + "/agent-tools.html")});
      await page.evaluate(() => {
        document.getElementById("otp").setAttribute("autocomplete", "one-time-code");
        document.getElementById("user").setAttribute("autocomplete", "current-password");
      });
      await page.fill("#pass", "hunter22-pass");
      await page.fill("#otp", "731904");
      await page.fill("#user", "ab");
      await page.fill("#apikey", "plain-visible-1");
      const out = {
        pass: await page.locator("#pass").inputValue(),
        otp: await page.locator("#otp").inputValue(),
        short: await page.locator("#user").inputValue(),
        plain: await page.locator("#apikey").inputValue(),
        tree: String(await snapshot()),
      };
      await page.fill("#pass", "");
      out.empty = await page.locator("#pass").inputValue();
      console.log(JSON.stringify(out));
    `);
    assert.equal(r.ok, true, r.error);
    const out = JSON.parse(lines.at(-1));
    assert.equal(out.pass, "********");
    assert.equal(out.otp, "********");
    assert.equal(out.short, "********", "a short value is masked when it is the whole string");
    assert.equal(out.plain, "plain-visible-1");
    assert.equal(out.empty, "");
    assert.ok(!out.tree.includes("731904") && !out.tree.includes("hunter22-pass"), out.tree);
    assert.ok(out.tree.includes("plain-visible-1"), out.tree);
  } finally {
    hosted.repl.dispose();
    await driver.detach();
    await browser.close();
    await servers.close();
    removeTestDir(dir);
    removeTestDirIfEmpty(host.tmpdir);
  }
});
