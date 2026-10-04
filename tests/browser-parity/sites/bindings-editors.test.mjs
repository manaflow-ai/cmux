// Google editor writes do exactly what the preview (or, for a private
// file, the call) named, or fail: sharing is checked again right before the
// write, a Docs anchor must still occur once in the same document, a
// Sheets append must still land after the last row, and Slides notes go to
// the slide the draft named by its object id, wherever it moved.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("bindings-editors");
const files = env.state.editors.files;
const DOC_ID = "1docPRIVATE000000000000000000000x";
const DOC = `https://docs.google.com/document/d/${DOC_ID}/edit`;

test("a private-file edit re-checks sharing right before the write; a file shared meanwhile is not edited", async () => {
  const doc = files.get(DOC_ID);
  const before = JSON.stringify(doc.blocks);
  doc.shareOnExport = true;
  try {
    assert.match(await s.error(`sites.googleDocs.replace(${JSON.stringify(DOC)}, "Intro", "Opening")`), /sharing_changed|sharing is now/);
    assert.equal(JSON.stringify(doc.blocks), before, "the now-shared doc was edited without a draft");
  } finally {
    doc.shared = false;
    doc.shareOnExport = false;
  }
});

test("a confirmed editor draft re-checks sharing right before the write; sharing changed since the preview edits nothing", async () => {
  const doc = files.get(DOC_ID);
  const before = JSON.stringify(doc.blocks);
  doc.shared = true;
  try {
    await s.run(`var shareD = await sites.googleDocs.replace(${JSON.stringify(DOC)}, "Intro", "Opening")`);
    assert.equal((await s.value("shareD.preview")).sharing, "Share. Anyone with the link can view.");
    doc.shareText = "Anyone on the internet with the link can edit";
    assert.match(await s.error("sites.googleDocs.replace(shareD.id, { confirm: true })"), /sharing_changed|sharing is now/);
    assert.equal(JSON.stringify(doc.blocks), before);
  } finally {
    doc.shared = false;
    doc.shareText = null;
  }
});

test("googleDocs.insertAfter: the draft states the anchor's single match and position; a second match or another change since the preview edits nothing", async () => {
  const doc = files.get(DOC_ID);
  doc.shared = true;
  const original = doc.blocks.map((b) => ({ ...b }));
  try {
    await s.run(`var insD = await sites.googleDocs.insertAfter(${JSON.stringify(DOC)}, "Closing line.", " Bye.")`);
    // A collaborator adds a second anchor after the preview.
    doc.blocks.push({ type: "paragraph", text: "Closing line." });
    const before = JSON.stringify(doc.blocks);
    assert.match(await s.error("sites.googleDocs.insertAfter(insD.id, { confirm: true })"), /document_changed|occurs 2 times/);
    assert.equal(JSON.stringify(doc.blocks), before, "Replace all broadened the edit to the new match");
    const p = await s.value("insD.preview");
    assert.equal(p.matches, 1);
    assert.equal(typeof p.at, "number");
    // Another change (the anchor still occurs once) also fails the confirmation.
    doc.blocks.pop();
    await s.run(`var insD2 = await sites.googleDocs.insertAfter(${JSON.stringify(DOC)}, "Closing line.", " Bye.")`);
    doc.blocks[1] = { type: "paragraph", text: "Intro paragraph, revised." };
    const before2 = JSON.stringify(doc.blocks);
    assert.match(await s.error("sites.googleDocs.insertAfter(insD2.id, { confirm: true })"), /document_changed|document changed/);
    assert.equal(JSON.stringify(doc.blocks), before2);
  } finally {
    doc.blocks = original;
    doc.shared = false;
  }
});

test("googleSheets.append: rows added after the preview are never overwritten; the confirmation fails instead", async () => {
  const SHEET = "https://docs.google.com/spreadsheets/d/1sheetSHARED00000000000000000000x/edit#gid=0";
  const cells = files.get("1sheetSHARED00000000000000000000x").sheets[0].cells;
  await s.run(`var apD = await sites.googleSheets.append(${JSON.stringify(SHEET)}, [["Tax", "50"]])`);
  assert.equal((await s.value("apD.preview")).range, "A5:B5");
  // A collaborator adds a row where the append would go.
  cells.set("A5", "Insurance");
  cells.set("B5", "80");
  try {
    assert.match(await s.error("sites.googleSheets.append(apD.id, { confirm: true })"), /sheet_changed|rows were added|last row/);
    assert.deepEqual([cells.get("A5"), cells.get("B5")], ["Insurance", "80"], "the collaborator's row was overwritten");
  } finally {
    cells.delete("A5");
    cells.delete("B5");
  }
});
