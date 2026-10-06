// Editing tools for Google Sheets, Docs and Slides against mock editors
// (mock-editors.mjs): reads through the export endpoints, writes through the
// editor UI with real input, drafts for files others can see.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";
import { zip } from "./mock-editors.mjs";

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
  assert.deepEqual(await s.confirmed(`sites.googleSheets.write(${JSON.stringify(f.url)}, "A1", [["a", "b"]])`), { status: "written", range: "A1:B1", verified: true });
  assert.deepEqual(files.get(f.id).edits, ["typed", "typed"]);
  await s.confirmed(`sites.googleDrive.trash(${JSON.stringify(f.url)})`);
});

test("googleSheets.append, write and clear on a private sheet are drafts too; confirmed, they write and verify", async () => {
  const f = await s.value('sites.googleDrive.create("spreadsheets", "cmux REPL test")');
  assert.match(f.url, /^https:\/\/docs\.google\.com\/spreadsheets\/d\/[\w-]+\/edit$/);
  assert.equal(f.title, "cmux REPL test");
  assert.equal(files.get(f.id).title, "cmux REPL test", "the rename reached the file");
  assert.deepEqual(await s.confirmed(`sites.googleSheets.write(${JSON.stringify(f.url)}, "A1", [["a", "b"], ["1", "=SUM(A2:A2)"]])`), { status: "written", range: "A1:B2", verified: true });
  assert.deepEqual(await s.confirmed(`sites.googleSheets.append(${JSON.stringify(f.url)}, [["2", "x"]])`), { status: "written", range: "A3:B3", verified: true });
  assert.deepEqual((await s.value(`sites.googleSheets.read(${JSON.stringify(f.url)})`)).rows, [["a", "b"], ["1", "1"], ["2", "x"]]);
  assert.deepEqual(await s.confirmed(`sites.googleSheets.clear(${JSON.stringify(f.url)}, "A3:B3")`), { status: "cleared", range: "A3:B3", verified: true });
  assert.equal((await s.value(`sites.googleSheets.read(${JSON.stringify(f.url)})`)).rows.length, 2);
  assert.deepEqual(await s.confirmed(`sites.googleDrive.trash(${JSON.stringify(f.url)})`), { status: "trashed", verified: true });
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

test("googleDocs.replace, insertAfter and append edit a private doc through Find and replace and verify once confirmed", async () => {
  assert.deepEqual(await s.confirmed(`sites.googleDocs.replace(${JSON.stringify(DOC)}, "Intro", "Opening")`), { status: "replaced", count: 1, verified: true });
  assert.deepEqual(await s.confirmed(`sites.googleDocs.insertAfter(${JSON.stringify(DOC)}, "Closing line.", " Thanks.")`), { status: "inserted", verified: true });
  assert.match(await s.error(`sites.googleDocs.insertAfter(${JSON.stringify(DOC)}, "it", "!")`), /anchor "it" occurs 2 times/);
  const blocks = files.get("1docPRIVATE000000000000000000000x").blocks;
  assert.equal(blocks[1].text, "Opening paragraph.");
  assert.equal(blocks[5].text, "Closing line. Thanks.");
  assert.deepEqual(await s.confirmed(`sites.googleDocs.append(${JSON.stringify(DOC)}, "Last words.")`), { status: "appended", verified: true });
  assert.deepEqual(blocks.at(-1), { type: "paragraph", text: "Last words." });
});

test("googleSlides.slides lists each slide's title, text and speaker notes; a confirmed replace edits a private deck", async () => {
  assert.deepEqual(await s.value(`sites.googleSlides.slides(${JSON.stringify(DECK)})`), [
    { index: 1, title: "Roadmap", text: ["Roadmap", "Q1: ship", "Q2: grow"], notes: "Say hello" },
    { index: 2, title: "Risks", text: ["Risks", "Time"], notes: "Keep short" },
  ]);
  assert.deepEqual(await s.confirmed(`sites.googleSlides.replace(${JSON.stringify(DECK)}, "Q2: grow", "Q2: scale")`), { status: "replaced", count: 1, verified: true });
  assert.equal(files.get("1deckPRIVATE00000000000000000000x").slides[0].body[1], "Q2: scale");
});

test("googleSlides.setNotes replaces one slide's speaker notes on a private deck and verifies once confirmed", async () => {
  assert.deepEqual(await s.confirmed(`sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 2, "First line\\nSecond line")`), { status: "notes set", slide: 2, verified: true });
  const slides = files.get("1deckPRIVATE00000000000000000000x").slides;
  assert.equal(slides[1].notes, "First line\nSecond line");
  assert.equal(slides[0].notes, "Say hello");
  assert.deepEqual(await s.confirmed(`sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 2, "Replaced")`), { status: "notes set", slide: 2, verified: true });
  assert.equal(slides[1].notes, "Replaced");
  assert.match(await s.error(`sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 9, "x")`), /slide 9 does not exist; the deck has 2 slides/);
});

test("editing a shared doc or deck is a draft until confirmed", async () => {
  env.state.editors.files.get("1docPRIVATE000000000000000000000x").shared = true;
  try {
    const d = await s.value(`sites.googleDocs.replace(${JSON.stringify(DOC)}, "Plan", "Plan B")`);
    assert.equal(d.status, "draft");
    const { textHash, ...shown } = d.preview;
    assert.deepEqual(shown, { account: "ada@example.com", accountId: "1001", fileId: "1docPRIVATE000000000000000000000x", title: "Plan", sharing: "Share. Anyone with the link can view.", find: "Plan", replace: "Plan B", matches: 1, at: [0] });
    assert.match(textHash, /^[0-9a-f]{16}$/);
    assert.equal(files.get("1docPRIVATE000000000000000000000x").blocks[0].text, "Plan");
  } finally {
    env.state.editors.files.get("1docPRIVATE000000000000000000000x").shared = false;
  }
});

// The sharing label a draft shows is read only from the editor's own Share
// button in its title bar: a label that says private elsewhere in the
// page, or a second, disagreeing label inside the button, is never shown.
test("a decoy Share label never shows a shared file as private", async () => {
  const doc = env.state.editors.files.get("1docPRIVATE000000000000000000000x");
  const before = JSON.stringify(doc.blocks);
  doc.shared = true;
  try {
    for (const where of ["inside", "page"]) {
      doc.decoyShare = where;
      // Two disagreeing labels in the button make the sharing unknown,
      // which drafts nothing; a label elsewhere is ignored.
      const r = await s.run(`var decoyD = await sites.googleDocs.replace(${JSON.stringify(DOC)}, "Plan", "Plan B")`);
      if (r.error) assert.match(r.error, /could not read the file's sharing/, `decoy ${where}`);
      else {
        const d = await s.value("decoyD");
        assert.equal(d.status, "draft", `decoy ${where}: ${JSON.stringify(d)}`);
        assert.equal(d.preview.sharing, "Share. Anyone with the link can view.", `decoy ${where}`);
      }
      assert.equal(JSON.stringify(doc.blocks), before, `decoy ${where}: the file changed`);
    }
  } finally {
    doc.shared = false;
    doc.decoyShare = null;
  }
});

// Crafted exports (a shared file's owner controls what Google exports):
// the xlsx/pptx reader bounds the ZIP it unzips (site-tools.md, "Editing
// Google files"): 10,000 entries, 64 MiB per entry and in all, and
// an entry never decompresses past its declared size.
const MiB = 1024 * 1024;
const WORKBOOK = [
  ["xl/workbook.xml", '<workbook xmlns:r="r"><sheets><sheet name="A" sheetId="1" r:id="rId1"/></sheets></workbook>'],
  ["xl/_rels/workbook.xml.rels", '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>'],
];
async function cellsFailure(exportBody) {
  const id = env.state.editors.add({ kind: "spreadsheets", title: "crafted", shared: true, sheets: [{ name: "A", gid: "0", cells: new Map() }], exportBody });
  const url = `https://docs.google.com/spreadsheets/d/${id}/edit`;
  return s.value(`sites.googleSheets.cells(${JSON.stringify(url)}).then((r) => ({ ok: r }), (e) => ({ code: e.code, message: e.message }))`);
}

test("googleSheets.cells refuses an entry that inflates past 64 MiB (a high-ratio export)", async () => {
  const r = await cellsFailure(zip([...WORKBOOK, ["xl/worksheets/sheet1.xml", Buffer.alloc(70 * MiB, 0x20)]]));
  assert.equal(r.code, "limit", JSON.stringify(r).slice(0, 300));
  assert.match(r.message, /xl\/worksheets\/sheet1\.xml declares \d+ bytes.*67108864 bytes per entry/);
});

test("googleSheets.cells reads one entry of 40 MiB (under the per-entry cap)", async () => {
  const big = '<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>big</t></is></c></row></sheetData></worksheet>' + " ".repeat(40 * MiB);
  const r = await cellsFailure(zip([...WORKBOOK, ["xl/worksheets/sheet1.xml", big]]));
  assert.deepEqual(r.ok && r.ok.cells, [{ cell: "A1", value: "big" }], JSON.stringify(r).slice(0, 300));
});

test("googleSlides.slides stops a pptx entry at its declared size (the same bounded reader)", async () => {
  const slide = "<p:sld><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>x</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>" + " ".repeat(20 * MiB);
  const id = env.state.editors.add({ kind: "presentation", title: "crafted deck", shared: true, slides: [{ id: "g0", title: "", body: [], notes: "" }], exportBody: zip([["ppt/slides/slide1.xml", slide, { size: 100 }]]) });
  const url = `https://docs.google.com/presentation/d/${id}/edit`;
  const r = await s.value(`sites.googleSlides.slides(${JSON.stringify(url)}).then((r) => ({ ok: r }), (e) => ({ code: e.code, message: e.message }))`);
  assert.equal(r.code, "limit", JSON.stringify(r).slice(0, 300));
  assert.match(r.message, /^googleSlides\.slides: ppt\/slides\/slide1\.xml decompresses past its declared size of 100 bytes/);
});

test("googleSheets.cells stops an entry at its declared size (a lying header)", async () => {
  const r = await cellsFailure(zip([...WORKBOOK, ["xl/worksheets/sheet1.xml", Buffer.alloc(20 * MiB, 0x20), { size: 100 }]]));
  assert.equal(r.code, "limit", JSON.stringify(r).slice(0, 300));
  assert.match(r.message, /past its declared size of 100 bytes/);
});

test("googleSheets.cells refuses an entry shorter than its declared size", async () => {
  const r = await cellsFailure(zip([...WORKBOOK, ["xl/worksheets/sheet1.xml", "<worksheet/>", { size: 5000 }]]));
  assert.equal(r.code, "unexpected", JSON.stringify(r).slice(0, 300));
  assert.match(r.message, /declares 5000 bytes but holds 12/);
});

test("googleSheets.cells stops when the entries together inflate past 64 MiB", async () => {
  const sheets = [1, 2, 3].map((n) => [`xl/worksheets/sheet${n}.xml`, Buffer.alloc(30 * MiB, 0x20)]);
  const r = await cellsFailure(zip([...WORKBOOK, ...sheets]));
  assert.equal(r.code, "limit", JSON.stringify(r).slice(0, 300));
  assert.match(r.message, /67108864 bytes/);
});

test("googleSheets.cells refuses an export of more than 10,000 entries", async () => {
  const many = Array.from({ length: 10001 }, (_, n) => [`x/${n}`, ""]);
  const r = await cellsFailure(zip([...WORKBOOK, ...many]));
  assert.equal(r.code, "limit", JSON.stringify(r).slice(0, 300));
  assert.match(r.message, /10003 entries.*10000/);
});

test("googleSheets.cells refuses offsets outside the archive", async () => {
  const bytes = zip([...WORKBOOK, ["xl/worksheets/sheet1.xml", "<worksheet/>"]]);
  // The last central record's local header offset, pointed past the end.
  const cd = bytes.readUInt32LE(bytes.length - 22 + 16);
  let p = cd;
  for (let n = 0; n < 2; n++) p += 46 + bytes.readUInt16LE(p + 28) + bytes.readUInt16LE(p + 30) + bytes.readUInt16LE(p + 32);
  bytes.writeUInt32LE(bytes.length + 1000, p + 42);
  const r = await cellsFailure(bytes);
  assert.equal(r.code, "unexpected", JSON.stringify(r).slice(0, 300));
  assert.match(r.message, /not a valid zip file/);
});
