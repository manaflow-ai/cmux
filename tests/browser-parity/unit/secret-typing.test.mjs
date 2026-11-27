// Secret typing in main's shape on hosts that advertise "secret.insert":
// secret(name) gives agent code a name, never a {__secret} handle, and the
// runtime asks the host to type it with input.insertText { secret }. The
// reference host advertises the capability; the Rust host gains it with
// the browser lead's driver_call change, and until then the runtime keeps
// sending handles (scenario 32 on host-headless).
//
//   node --test tests/browser-parity/unit/secret-typing.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime, createDevBrowser, createNodeHost, createHostedRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { makeTestDir, removeTestDir, removeTestDirIfEmpty } from "../lib/test-dirs.mjs";

const ns = loadRuntime();

test("secret(name) is a name, and fill and type send input.insertText { secret }", async () => {
  const servers = await startFixtureServers();
  const browser = await createDevBrowser();
  const driver = browser.driver();
  const dir = makeTestDir("secret-typing-");
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId: `secret-typing-${process.pid}`, print: (level, text) => lines.push(text) });
  const hosted = createHostedRepl(ns, { host, driver });
  try {
    const r = await hosted.repl.evaluate(`
      secrets.set("pw", "s3cret-Value-9", { domains: ["localhost"] });
      await page.goto(${JSON.stringify(servers.origins.primary + "/agent-tools.html")});
      const s = secret("pw");
      console.log(JSON.stringify(s), JSON.stringify([s]), Object.keys(s).join(","));
      await page.fill("#apikey", s);
      await page.locator("#pass").pressSequentially(s);
    `);
    assert.equal(r.ok, true, r.error);
    assert.equal(lines.join("\n"), '"<secret:pw>" ["<secret:pw>"] name');
    const inserts = hosted.vmDriverCalls().filter((c) => c.method === "input.insertText");
    assert.equal(inserts.length, 2, JSON.stringify(inserts));
    for (const c of inserts) {
      assert.equal(c.params.secret, "pw");
      assert.equal(c.params.text, undefined, "no text or handle crosses for a secret");
    }
    assert.equal(await hosted.pageValue("#apikey"), "s3cret-Value-9");
    assert.equal(await hosted.pageValue("#pass"), "s3cret-Value-9");
  } finally {
    hosted.repl.dispose();
    await driver.detach();
    await browser.close();
    await servers.close();
    removeTestDir(dir);
    removeTestDirIfEmpty(host.tmpdir);
  }
});
