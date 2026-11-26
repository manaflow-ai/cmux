// sites.meet on a mock Meet call: captions off, turned on, read and followed.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("meet");

test("meet: no call open fails as not_found", async () => {
  assert.match(await s.error("sites.meet.captions()"), /no Google Meet call is open/);
});

test("meet: captions start off; captionsOn clicks Meet's button; captions reads speaker lines", async () => {
  await s.run('await page.goto("https://meet.google.com/abc-defg-hij")');
  const off = await s.value("sites.meet.captions()");
  assert.equal(off.on, false);
  assert.deepEqual(off.lines, []);
  assert.match(await s.error("sites.meet.listen({ seconds: 1 })"), /captions are off/);
  assert.equal((await s.value("sites.meet.captionsOn()")).on, true);
  await s.run("await sleep(1500)");
  const r = await s.value("sites.meet.captions()");
  assert.equal(r.on, true);
  assert.deepEqual(r.lines, [
    { speaker: "Ada", text: "Can the agent look at the flaky test" },
    { speaker: "Grace", text: "Sure I will open the PR" },
  ]);
});

test("meet: listen merges a line that grows word by word into one transcript line", async () => {
  await s.run('await page.goto("https://meet.google.com/abc-defg-hij")');
  const t = await s.value("sites.meet.listen({ seconds: 2.5, turnOn: true, interval: 100 })");
  assert.deepEqual(t.lines.map((x) => [x.speaker, x.text]), [
    ["Ada", "Can the agent look at the flaky test"],
    ["Grace", "Sure I will open the PR"],
  ]);
  assert.equal(await s.value("sites.meet.text(" + JSON.stringify(t) + ")"), "Ada: Can the agent look at the flaky test\nGrace: Sure I will open the PR");
  assert.match(await s.value("JSON.stringify(sites.list())"), /"meet"/);
});
