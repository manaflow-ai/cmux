// Editing tools for Google Sheets, Docs and Slides against mock editors
// (mock-editors.mjs): reads through the export endpoints, writes through the
// editor UI with real input, drafts for files others can see.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("editors");
const files = env.state.editors.files;
const SHEET = "https://docs.google.com/spreadsheets/d/1sheetSHARED00000000000000000000x/edit#gid=0";
const DOC = "https://docs.google.com/document/d/1docPRIVATE000000000000000000000x/edit";
const DECK = "https://docs.google.com/presentation/d/1deckPRIVATE00000000000000000000x/edit";

test("googleSheets.cells reads values and formulas (A1 range, any tab) from the xlsx export", async () => {
  const r = await s.value(`sites.googleSheets.cells(${JSON.stringify(SHEET)}, { range: "A3:B4" })`);
  assert.deepEqual(r, { sheet: "Budget", range: "A3:B4", cells: [{ cell: "A3", value: "Food" }, { cell: "B3", value: "300" }, { cell: "A4", value: "Total" }, { cell: "B4", value: "1500", formula: "=SUM(B2:B3)" }] });
  const notes = await s.value(`sites.googleSheets.cells(${JSON.stringify(SHEET)}, { sheet: "Notes" })`);
  assert.deepEqual(notes.cells, [{ cell: "A1", value: "remember" }]);
});

test("googleSheets.find returns the cells whose value contains the text", async () => {
  assert.deepEqual(await s.value(`sites.googleSheets.find(${JSON.stringify(SHEET)}, "o")`), [{ sheet: "Budget", cell: "A3", value: "Food" }, { sheet: "Budget", cell: "A4", value: "Total" }, { sheet: "Budget", cell: "B1", value: "Cost" }].sort((a, b) => (a.sheet + a.cell).localeCompare(b.sheet + b.cell)));
});

test("googleSheets.write to a shared sheet is a draft; the confirmed draft pastes TSV at the range and verifies", async () => {
  const d = await s.value(`sites.googleSheets.write(${JSON.stringify(SHEET)}, "C1", [["Paid"], ["yes"]])`);
  assert.equal(d.status, "draft");
  assert.match(d.category, /\[9\]/);
  assert.equal(files.get("1sheetSHARED00000000000000000000x").sheets[0].cells.get("C1"), undefined);
  const r = await s.value(`sites.googleSheets.write(${JSON.stringify(d.id)}, { confirm: true })`);
  assert.deepEqual(r, { status: "written", range: "C1:C2", verified: true });
  assert.equal(files.get("1sheetSHARED00000000000000000000x").sheets[0].cells.get("C2"), "yes");
  assert.deepEqual(files.get("1sheetSHARED00000000000000000000x").edits, ["paste"], "one paste wrote the whole range");
});

test("googleSheets.write types the cells when the editor drops the paste", async () => {
  const f = await s.value('sites.googleDrive.create("spreadsheets", "cmux REPL paste fallback")');
  files.get(f.id).ignorePaste = true;
  assert.deepEqual(await s.value(`sites.googleSheets.write(${JSON.stringify(f.url)}, "A1", [["a", "b"]])`), { status: "written", range: "A1:B1", verified: true });
  assert.deepEqual(files.get(f.id).edits, ["typed", "typed"]);
  await s.value(`sites.googleDrive.trash(${JSON.stringify(f.url)})`);
});

test("googleSheets.append, write and clear on a private sheet run at once and verify", async () => {
  const f = await s.value('sites.googleDrive.create("spreadsheets", "cmux REPL test")');
  assert.match(f.url, /^https:\/\/docs\.google\.com\/spreadsheets\/d\/[\w-]+\/edit$/);
  assert.equal(f.title, "cmux REPL test");
  assert.equal(files.get(f.id).title, "cmux REPL test", "the rename reached the file");
  assert.deepEqual(await s.value(`sites.googleSheets.write(${JSON.stringify(f.url)}, "A1", [["a", "b"], ["1", "=SUM(A2:A2)"]])`), { status: "written", range: "A1:B2", verified: true });
  assert.deepEqual(await s.value(`sites.googleSheets.append(${JSON.stringify(f.url)}, [["2", "x"]])`), { status: "written", range: "A3:B3", verified: true });
  assert.deepEqual((await s.value(`sites.googleSheets.read(${JSON.stringify(f.url)})`)).rows, [["a", "b"], ["1", "1"], ["2", "x"]]);
  assert.deepEqual(await s.value(`sites.googleSheets.clear(${JSON.stringify(f.url)}, "A3:B3")`), { status: "cleared", range: "A3:B3", verified: true });
  assert.equal((await s.value(`sites.googleSheets.read(${JSON.stringify(f.url)})`)).rows.length, 2);
  assert.deepEqual(await s.value(`sites.googleDrive.trash(${JSON.stringify(f.url)})`), { status: "trashed", verified: true });
  assert.equal(files.get(f.id).trashed, true);
});

test("googleDocs.structure returns headings, paragraphs, lists and tables in order", async () => {
  assert.deepEqual(await s.value(`sites.googleDocs.structure(${JSON.stringify(DOC)})`), {
    title: "Plan",
    blocks: [
      { type: "heading", level: 1, text: "Plan" },
      { type: "paragraph", text: "Intro paragraph." },
      { type: "heading", level: 2, text: "Goals" },
      { type: "list", ordered: false, items: ["Ship it", "Measure it"] },
      { type: "table", rows: [["Owner", "Task"], ["Ada", "Draft"]] },
      { type: "paragraph", text: "Closing line." },
    ],
  });
});

test("googleDocs.replace, insertAfter and append edit a private doc through Find and replace and verify", async () => {
  assert.deepEqual(await s.value(`sites.googleDocs.replace(${JSON.stringify(DOC)}, "Intro", "Opening")`), { status: "replaced", count: 1, verified: true });
  assert.deepEqual(await s.value(`sites.googleDocs.insertAfter(${JSON.stringify(DOC)}, "Closing line.", " Thanks.")`), { status: "inserted", verified: true });
  assert.match(await s.error(`sites.googleDocs.insertAfter(${JSON.stringify(DOC)}, "it", "!")`), /anchor "it" occurs 2 times/);
  const blocks = files.get("1docPRIVATE000000000000000000000x").blocks;
  assert.equal(blocks[1].text, "Opening paragraph.");
  assert.equal(blocks[5].text, "Closing line. Thanks.");
  assert.deepEqual(await s.value(`sites.googleDocs.append(${JSON.stringify(DOC)}, "Last words.")`), { status: "appended", verified: true });
  assert.deepEqual(blocks.at(-1), { type: "paragraph", text: "Last words." });
});

test("googleSlides.slides lists each slide's title, text and speaker notes; replace edits a private deck", async () => {
  assert.deepEqual(await s.value(`sites.googleSlides.slides(${JSON.stringify(DECK)})`), [
    { index: 1, title: "Roadmap", text: ["Roadmap", "Q1: ship", "Q2: grow"], notes: "Say hello" },
    { index: 2, title: "Risks", text: ["Risks", "Time"], notes: "Keep short" },
  ]);
  assert.deepEqual(await s.value(`sites.googleSlides.replace(${JSON.stringify(DECK)}, "Q2: grow", "Q2: scale")`), { status: "replaced", count: 1, verified: true });
  assert.equal(files.get("1deckPRIVATE00000000000000000000x").slides[0].body[1], "Q2: scale");
});

test("googleSlides.setNotes replaces one slide's speaker notes on a private deck and verifies", async () => {
  assert.deepEqual(await s.value(`sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 2, "First line\\nSecond line")`), { status: "notes set", slide: 2, verified: true });
  const slides = files.get("1deckPRIVATE00000000000000000000x").slides;
  assert.equal(slides[1].notes, "First line\nSecond line");
  assert.equal(slides[0].notes, "Say hello");
  assert.deepEqual(await s.value(`sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 2, "Replaced")`), { status: "notes set", slide: 2, verified: true });
  assert.equal(slides[1].notes, "Replaced");
  assert.match(await s.error(`sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 9, "x")`), /slide 9 does not exist; the deck has 2 slides/);
});

test("editing a shared doc or deck is a draft until confirmed", async () => {
  env.state.editors.files.get("1docPRIVATE000000000000000000000x").shared = true;
  try {
    const d = await s.value(`sites.googleDocs.replace(${JSON.stringify(DOC)}, "Plan", "Plan B")`);
    assert.equal(d.status, "draft");
    assert.deepEqual(d.preview, { file: DOC, title: "Plan", find: "Plan", replace: "Plan B", matches: 1, at: [0], sharing: "Share. Anyone with the link can view.", account: "ada@example.com" });
    assert.equal(files.get("1docPRIVATE000000000000000000000x").blocks[0].text, "Plan");
  } finally {
    env.state.editors.files.get("1docPRIVATE000000000000000000000x").shared = false;
  }
});

// The sharing label decides between an immediate edit and a draft. It is
// read only from the editor's own Share button in its title bar: a label
// that says private elsewhere in the page, or a second, disagreeing label
// inside the button, never makes a shared file's edit immediate.
test("a decoy Share label never makes an edit of a shared file immediate", async () => {
  const doc = env.state.editors.files.get("1docPRIVATE000000000000000000000x");
  const before = JSON.stringify(doc.blocks);
  doc.shared = true;
  try {
    for (const where of ["inside", "page"]) {
      doc.decoyShare = where;
      const d = await s.value(`sites.googleDocs.replace(${JSON.stringify(DOC)}, "Plan", "Plan B")`);
      assert.equal(d.status, "draft", `decoy ${where}: ${JSON.stringify(d)}`);
      assert.notEqual(d.preview.sharing, "Share. Private to only me.", `decoy ${where}`);
      assert.equal(JSON.stringify(doc.blocks), before, `decoy ${where}: the file changed`);
    }
  } finally {
    doc.shared = false;
    doc.decoyShare = null;
  }
});
