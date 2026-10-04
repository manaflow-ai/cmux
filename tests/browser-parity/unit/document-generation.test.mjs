// Element handles and snapshot refs belong to the document that issued them
// (docs/browser-repl/README.md, Snapshot; driver-protocol.md, handles). A
// frame keeps its identity when it navigates, and the page agent of the new
// document numbers its handles and refs from the start again, so a retained
// handle or ref could name an element of another document, possibly another
// origin. Any use of one from a previous document fails `stale` and never
// acts on the new document. Runs on Playwright WebKit through the dev driver.
//
//   node --test tests/browser-parity/unit/document-generation.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { runDevCells } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";

const results = (outputs) =>
  outputs.map((o, i) => {
    assert.equal(o.error, null, `cell ${i + 1} failed: ${o.error}\n${o.output}`);
    return o.output ? JSON.parse(o.output.trim().split("\n").at(-1)) : null;
  });

// Twenty buttons that count their clicks in the document title.
const buttons = (label) => `(label) => {
  document.title = "0";
  document.body.innerHTML = Array.from({ length: 20 }, (_, i) => '<button id="' + label + i + '">' + label + ' ' + i + '</button>').join("");
  for (const b of document.querySelectorAll("button")) b.onclick = () => { document.title = String(Number(document.title) + 1); };
}`;

test("an element handle from a previous document fails stale", async () => {
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  try {
    const [out] = results(await runDevCells([
      {
        code: `
await page.goto(${JSON.stringify(primary)} + "/index.html?one");
await page.evaluate(${buttons()}, "old");
const old = await page.locator("#old0").elementHandle();
await page.goto(${JSON.stringify(primary)} + "/index.html?two");
await page.evaluate(${buttons()}, "new");
// The new document hands out its own handles, from the same numbers.
await page.locator("button").elementHandles();
const out = {};
out.evaluate = await old.evaluate((el) => el.id).then((id) => "acted on " + id, (e) => e.message);
out.click = await old.click({ timeout: 2000 }).then(() => "clicked", (e) => e.message);
out.clicks = await page.title();
console.log(JSON.stringify(out));`,
      },
    ]));
    assert.match(out.evaluate, /previous document/);
    assert.match(out.click, /previous document/);
    assert.equal(out.clicks, "0", "nothing in the new document was clicked");
  } finally {
    await servers.close();
  }
});

test("a snapshot ref from a previous document fails stale when another session numbered the new one", async () => {
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  try {
    const out = results(await runDevCells([
      // A one-shot run opens and keeps a tab: the user's tab from then on.
      { code: `const t = await tabs.open(${JSON.stringify(primary)} + "/index.html?shared"); await t.evaluate(${buttons()}, "old"); await t.keep(); console.log("null");` },
      {
        session: "a",
        code: `
await tabs.use((await tabs.list()).find((t) => t.url.endsWith("?shared")).id);
const oldRef = /button "old 0" \\[ref=(e\\d+)\\]/.exec((await snapshot({ interactive: true })).tree)[1];
console.log(JSON.stringify(oldRef));`,
      },
      {
        // Another session drives the same tab to a new document and reads it first.
        session: "b",
        code: `
await tabs.use((await tabs.list()).find((t) => t.url.endsWith("?shared")).id);
await page.goto(${JSON.stringify(primary)} + "/index.html?shared-two");
await page.evaluate(${buttons()}, "new");
console.log(JSON.stringify((await snapshot({ interactive: true })).tree));`,
      },
      {
        session: "a",
        code: `
const out = {};
out.click = await page.locator(oldRef).click({ timeout: 2000 }).then(() => "clicked", (e) => e.message);
out.clicks = await page.title();
console.log(JSON.stringify(out));`,
      },
    ]));
    const [, oldRef, newTree, used] = out;
    assert.ok(newTree.includes(`[ref=${oldRef}]`), `the new document reuses ${oldRef}:\n${newTree}`);
    assert.match(used.click, /previous document/);
    assert.equal(used.clicks, "0", "nothing in the new document was clicked");
  } finally {
    await servers.close();
  }
});
