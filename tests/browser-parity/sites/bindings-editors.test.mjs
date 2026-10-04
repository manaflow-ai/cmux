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
