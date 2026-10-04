// Session behaviors stop at tabs the session did not open
// (docs/browser-repl/README.md, Sessions and tabs): in a user's tab that a
// session only drives, a dialog, file chooser or download without a handler
// stays with the user; a handler the agent registered on that page takes
// just that event. A dialog or file chooser the agent's own click opens goes
// to the agent, though: cmux's UI must not come up in front of the user for
// it, nor leave the agent waiting for the user's answer. Runs on Playwright WebKit through the dev driver, which
// stands in for the user's own UI by dismissing dialogs, leaving the file
// chooser unanswered and keeping the download from the session.
//
//   node --test tests/browser-parity/unit/tab-ownership.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { runDevCells } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";

const results = (outputs) =>
  outputs.map((o, i) => {
    assert.equal(o.error, null, `cell ${i + 1} failed: ${o.error}\n${o.output}`);
    return o.output ? JSON.parse(o.output.trim().split("\n").at(-1)) : null;
  });

test("a user's tab: only events the agent handles go to the session", async () => {
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  try {
    const outputs = await runDevCells([
      // A one-shot run opens and keeps a tab; once it ends the tab is the user's.
      { code: `const t = await tabs.open(${JSON.stringify(primary)} + "/dialogs.html?user-owned"); await t.keep(); console.log("null");` },
      {
        session: "agent",
        code: `
const row = (await tabs.list()).find((t) => t.url.endsWith("?user-owned"));
const user = await tabs.use(row.id);
const out = {};
await user.locator("#confirm").click();
out.dialogHeld = !!user.dialog();
if (user.dialog()) await user.dialog().dismiss();
out.dialogResult = await user.locator("#r").textContent();
user.once("dialog", (d) => d.accept());
await user.locator("#confirm").click();
out.dialogWithListener = await user.locator("#r").textContent();
await user.goto(${JSON.stringify(primary)} + "/files.html?user-owned");
await user.locator("#one").click();
await sleep(300);
out.chooserHeld = !!user.fileChooser();
if (user.fileChooser()) await user.fileChooser().cancel();
const chooser = user.waitForEvent("filechooser");
await user.locator("#many").click();
out.chooserWithListener = (await chooser).isMultiple();
await user.locator("#dl").click();
await sleep(500);
out.downloadsWithoutListener = session.downloads().length;
const download = user.waitForEvent("download");
await user.locator("#dl").click();
out.downloadWithListener = (await download).suggestedFilename();
await user.close();
console.log(JSON.stringify(out));`,
      },
    ]);
    assert.deepEqual(results(outputs)[1], {
      dialogHeld: true,
      dialogResult: "confirm false",
      dialogWithListener: "confirm true",
      chooserHeld: true,
      chooserWithListener: true,
      downloadsWithoutListener: 0,
      downloadWithListener: "parity-download.txt",
    });
  } finally {
    await servers.close();
  }
});

test("a tab the session opened: dialogs and choosers wait for the session without a handler", async () => {
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  try {
    const outputs = await runDevCells([
      {
        code: `
const own = await tabs.open(${JSON.stringify(primary)} + "/dialogs.html?session-owned");
const out = {};
await own.locator("#confirm").click();
out.dialogHeld = !!own.dialog();
await own.dialog().accept();
out.dialogResult = await own.locator("#r").textContent();
console.log(JSON.stringify(out));`,
      },
    ]);
    assert.deepEqual(results(outputs)[0], { dialogHeld: true, dialogResult: "confirm true" });
  } finally {
    await servers.close();
  }
});
