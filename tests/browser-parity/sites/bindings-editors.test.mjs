// Google editor writes are confirmed drafts that do exactly what the
// preview named, or fail: sharing and the account are read back right
// before the write, a Docs anchor must still occur once in the same
// document, a Sheets append must still land after the last row, and Slides
// notes go to the slide the draft named by its object id and title, at the
// same position.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("bindings-editors");
const files = env.state.editors.files;
const DOC_ID = "1docPRIVATE000000000000000000000x";
const DOC = `https://docs.google.com/document/d/${DOC_ID}/edit`;

test("a private file's edit is a draft too: its Share label is page text and never skips the confirmation", async () => {
  const doc = files.get(DOC_ID);
  const before = JSON.stringify(doc.blocks);
  // The file is shared, but its Share button (page text) says private.
  doc.shared = true;
  doc.shareText = "Private to only me";
  try {
    const d = await s.value(`sites.googleDocs.replace(${JSON.stringify(DOC)}, "Intro", "Opening")`);
    assert.equal(d.status, "draft", `a write ran at once: ${JSON.stringify(d)}`);
    assert.equal(JSON.stringify(doc.blocks), before, "the doc was edited without a confirmed draft");
  } finally {
    doc.shared = false;
    doc.shareText = null;
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
    assert.match(await s.error("sites.googleDocs.replace(shareD.id, { confirm: true })"), /target_mismatch|sharing is "Share. Anyone on the internet/);
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
    assert.match(await s.error("sites.googleDocs.insertAfter(insD.id, { confirm: true })"), /content_mismatch|matches is 2, not 1/);
    assert.equal(JSON.stringify(doc.blocks), before, "Replace all broadened the edit to the new match");
    const p = await s.value("insD.preview");
    assert.equal(p.matches, 1);
    assert.equal(typeof p.at, "number");
    // Another change (the anchor still occurs once) also fails the confirmation.
    doc.blocks.pop();
    await s.run(`var insD2 = await sites.googleDocs.insertAfter(${JSON.stringify(DOC)}, "Closing line.", " Bye.")`);
    doc.blocks[1] = { type: "paragraph", text: "Intro paragraph, revised." };
    const before2 = JSON.stringify(doc.blocks);
    assert.match(await s.error("sites.googleDocs.insertAfter(insD2.id, { confirm: true })"), /content_mismatch|textHash is/);
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
    assert.match(await s.error("sites.googleSheets.append(apD.id, { confirm: true })"), /content_mismatch|range is "A6:B6", not "A5:B5"/);
    assert.deepEqual([cells.get("A5"), cells.get("B5")], ["Insurance", "80"], "the collaborator's row was overwritten");
  } finally {
    cells.delete("A5");
    cells.delete("B5");
  }
});

test("googleSlides.setNotes: the draft names the slide by its object id and title at its position; a reorder or delete since the preview edits nothing", async () => {
  const DECK_ID = "1deckPRIVATE00000000000000000000x";
  const DECK = `https://docs.google.com/presentation/d/${DECK_ID}/edit`;
  const deck = files.get(DECK_ID);
  const original = deck.slides.map((x) => ({ ...x }));
  deck.shared = true;
  try {
    await s.run(`var snD = await sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 2, "Bound notes")`);
    const p = await s.value("snD.preview");
    assert.equal(p.slideId, "g1a2b3c_0_7");
    assert.equal(p.slideTitle, "Risks");
    // A collaborator moves "Risks" to the front.
    deck.slides = [deck.slides[1], deck.slides[0]];
    const before = JSON.stringify(deck.slides);
    assert.match(await s.error("sites.googleSlides.setNotes(snD.id, { confirm: true })"), /target_mismatch|slide is 1, not 2/);
    assert.equal(JSON.stringify(deck.slides), before, "notes were set after a reorder");
    // A collaborator deletes the drafted slide.
    await s.run(`var snD2 = await sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 1, "Gone")`);
    deck.slides = deck.slides.filter((x) => x.title !== "Risks");
    assert.match(await s.error("sites.googleSlides.setNotes(snD2.id, { confirm: true })"), /target_mismatch|slideId is null/);
    assert.equal(deck.slides[0].notes, "Say hello");
  } finally {
    deck.slides = original;
    deck.shared = false;
  }
});

// r10 sites#1: a collaborator reorders the deck while the draft is made
// (between the deck's export and the editor's filmstrip). The draft's
// title and object id must name the same slide, and the notes go there.
test("googleSlides.setNotes: a reorder while the draft is made never pairs one slide's title with another slide's id", async () => {
  const DECK_ID = "1deckPRIVATE00000000000000000000x";
  const DECK = `https://docs.google.com/presentation/d/${DECK_ID}/edit`;
  const deck = files.get(DECK_ID);
  const original = deck.slides.map((x) => ({ ...x }));
  deck.shared = true;
  deck.reorderOnEditorLoad = true;
  try {
    await s.run(`var snR = await sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 2, "Paired notes")`);
    const p = await s.value("snR.preview");
    const bound = deck.slides.find((x) => x.id === p.slideId);
    assert.ok(bound, `no slide ${p.slideId}`);
    assert.equal(p.slideTitle, bound.title, "the preview shows one slide's title and another slide's id");
    await s.value("sites.googleSlides.setNotes(snR.id, { confirm: true })");
    assert.equal(deck.slides.find((x) => x.title === p.slideTitle).notes, "Paired notes", "the notes went to another slide than the preview's title");
  } finally {
    deck.slides = original;
    deck.shared = false;
    deck.reorderOnEditorLoad = false;
  }
});

test("googleDocs.replace: the draft states the match count and positions; a new match or another change since the preview edits nothing", async () => {
  const doc = files.get(DOC_ID);
  doc.shared = true;
  const original = doc.blocks.map((b) => ({ ...b }));
  try {
    await s.run(`var repD = await sites.googleDocs.replace(${JSON.stringify(DOC)}, "Intro", "Opening")`);
    // A collaborator adds another match after the preview.
    doc.blocks.push({ type: "paragraph", text: "Intro, part two." });
    const before = JSON.stringify(doc.blocks);
    assert.match(await s.error("sites.googleDocs.replace(repD.id, { confirm: true })"), /content_mismatch|matches is 2, not 1/);
    assert.equal(JSON.stringify(doc.blocks), before, "Replace all edited a match the preview did not count");
    const p = await s.value("repD.preview");
    assert.equal(p.matches, 1);
    assert.equal(p.at.length, 1);
    assert.equal(typeof p.at[0], "number");
    // Docs' Find and replace ignores case by default: the count does too.
    await s.run(`var repD2 = await sites.googleDocs.replace(${JSON.stringify(DOC)}, "closing", "Final")`);
    assert.equal((await s.value("repD2.preview")).matches, 1);
  } finally {
    doc.blocks = original;
    doc.shared = false;
  }
});

test("googleSlides.replace: the draft states the match count per slide; a new match since the preview edits nothing", async () => {
  const DECK_ID = "1deckPRIVATE00000000000000000000x";
  const DECK = `https://docs.google.com/presentation/d/${DECK_ID}/edit`;
  const deck = files.get(DECK_ID);
  const original = deck.slides.map((x) => ({ ...x, body: [...x.body] }));
  deck.shared = true;
  try {
    await s.run(`var srD = await sites.googleSlides.replace(${JSON.stringify(DECK)}, "Time", "Budget")`);
    deck.slides[0].body.push("Time to ship");
    const before = JSON.stringify(deck.slides);
    assert.match(await s.error("sites.googleSlides.replace(srD.id, { confirm: true })"), /content_mismatch|matches is 2, not 1/);
    assert.equal(JSON.stringify(deck.slides), before, "Replace all edited a match the preview did not count");
    const p = await s.value("srD.preview");
    assert.equal(p.matches, 1);
    assert.deepEqual(p.at, [{ slide: 2, matches: 1 }]);
  } finally {
    deck.slides = original;
    deck.shared = false;
  }
});

test("googleDrive.trash: even a private file this session created needs a confirmed draft; shared after the preview, it is not trashed", async () => {
  const f = await s.value('sites.googleDrive.create("document", "cmux REPL trash binding")');
  const file = files.get(f.id);
  const d = await s.value(`sites.googleDrive.trash(${JSON.stringify(f.url)})`);
  assert.equal(d.status, "draft");
  assert.equal(file.trashed, false, "the file was trashed without a confirmed draft");
  assert.match(d.category, /\[1\]/);
  assert.equal(d.preview.sharing, "Share. Private to only me.");
  // Another session shares the file before the confirmation.
  file.shared = true;
  try {
    assert.match(await s.error(`sites.googleDrive.trash(${JSON.stringify(d.id)}, { confirm: true })`), /target_mismatch|sharing is/);
    assert.equal(file.trashed, false);
  } finally {
    file.shared = false;
  }
  assert.deepEqual(await s.confirmed(`sites.googleDrive.trash(${JSON.stringify(f.url)})`), { status: "trashed", verified: true });
  assert.equal(file.trashed, true);
});

test("googleDrive.trash: a confirmed draft re-checks sharing right before the trash; sharing changed since the preview trashes nothing", async () => {
  const doc = files.get(DOC_ID);
  try {
    await s.run(`var trD = await sites.googleDrive.trash(${JSON.stringify(DOC)})`);
    assert.equal((await s.value("trD.preview")).sharing, "Share. Private to only me.");
    doc.shared = true;
    assert.match(await s.error("sites.googleDrive.trash(trD.id, { confirm: true })"), /target_mismatch|sharing is/);
    assert.equal(doc.trashed, false, "a file shared since the preview was trashed");
  } finally {
    doc.shared = false;
    doc.trashed = false;
  }
});
