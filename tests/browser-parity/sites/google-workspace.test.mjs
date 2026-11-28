// sites.googleAccounts, googleDocs, googleSheets, googleSlides, googleDrive
// against mock Google endpoints (mock-sites.mjs).
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("google");

test("googleAccounts.list: signed-in accounts with their uid and Google account id, from ListAccounts", async () => {
  assert.deepEqual(await s.value("sites.googleAccounts.list()"), [
    { uid: 0, id: "1001", name: "Ada Lovelace", email: "ada@example.com", signedOut: false },
    { uid: 1, id: "1002", name: "Ada at Work", email: "ada@work.example", signedOut: false },
    { uid: 2, id: "1003", name: "Old Account", email: "old@example.com", signedOut: true },
  ]);
});

test("googleDocs.read: Markdown by default, title from the export's file name", async () => {
  const r = await s.value('sites.googleDocs.read("https://docs.google.com/document/d/DOC1/edit")');
  assert.deepEqual(r, { title: "Design Notes", text: "# Design Notes\n\nThe **plan**, in brief.\n\n![][image1]\n" });
  assert.equal((await s.value('sites.googleDocs.read("https://docs.google.com/document/d/DOC1/edit", { format: "txt" })')).text, "Design Notes\n\nThe plan, in brief.\n");
});

test("Docs Markdown reads drop inline image data (Google's Markdown export embeds images as data: definitions)", async () => {
  const r = await s.value('sites.googleDocs.read("https://docs.google.com/document/d/DOC1/edit")');
  assert.ok(!r.text.includes("data:image"), "no image data");
  assert.ok(r.text.length < 200);
});

test("googleDocs: the account comes from /u/N/ in the URL or { uid }; a wrong account is a clear 403", async () => {
  assert.equal((await s.value('sites.googleDocs.read("https://docs.google.com/document/u/1/d/DOCWORK/edit")')).title, "Work Plan");
  assert.equal((await s.value('sites.googleDocs.read("https://docs.google.com/document/d/DOCWORK/edit", { uid: 1 })')).title, "Work Plan");
  const err = await s.error('sites.googleDocs.read("https://docs.google.com/document/d/DOCWORK/edit")');
  assert.match(err, /HTTP 403.*uid 0.*Try another \{ uid \}/);
});

test("googleDocs.export writes the file and rejects formats Docs does not export", async () => {
  const r = await s.value('sites.googleDocs.export("https://docs.google.com/document/d/DOC1/edit", { format: "pdf" })');
  assert.equal(r.title, "Design Notes");
  assert.match(r.path, /Design_Notes-\d+\.pdf$/);
  assert.equal(fs.readFileSync(r.path, "utf8"), "%PDF-1.4 mock Design Notes");
  assert.match(await s.error('sites.googleDocs.export("https://docs.google.com/document/d/DOC1/edit", { format: "xlsx" })'), /format: expected one of md, pdf, docx/);
  assert.match(await s.error('sites.googleDocs.read("https://docs.google.com/spreadsheets/d/SHEET1/edit")'), /expected a Google Docs document, got a Google Sheets spreadsheet/);
});

test("googleSheets.info lists sheets; read parses CSV (quoted commas and newlines) per sheet", async () => {
  assert.deepEqual(await s.value('sites.googleSheets.info("https://docs.google.com/spreadsheets/d/SHEET1/edit#gid=0")'), { title: "Budget 2026", sheets: [{ name: "Budget", gid: "0" }, { name: "Q2 & Notes", gid: "123" }] });
  const r = await s.value('sites.googleSheets.read("https://docs.google.com/spreadsheets/d/SHEET1/edit")');
  assert.deepEqual(r.rows, [["Item", "Cost", "Note"], ["Rent", "1200", "monthly, fixed"], ["Food", "300", "line one\nline two"]]);
  const byName = await s.value('sites.googleSheets.read("https://docs.google.com/spreadsheets/d/SHEET1/edit", { sheet: "Q2 & Notes" })');
  assert.deepEqual([byName.sheet, byName.gid, byName.rows], ["Q2 & Notes", "123", [["Quarter", "Total"], ["Q2", "4500"]]]);
  const hashGid = await s.value('sites.googleSheets.read("https://docs.google.com/spreadsheets/d/SHEET1/edit#gid=123")');
  assert.equal(hashGid.rows[1][1], "4500");
  const range = await s.value('sites.googleSheets.read("https://docs.google.com/spreadsheets/d/SHEET1/edit", { range: "B2:C3" })');
  assert.deepEqual(range.rows, [["1200", "monthly, fixed"], ["300", "line one\nline two"]]);
  assert.match(await s.error('sites.googleSheets.read("https://docs.google.com/spreadsheets/d/SHEET1/edit", { sheet: "Nope" })'), /no sheet named "Nope"; sheets: Budget, Q2 & Notes/);
  const all = await s.value('sites.googleSheets.readAll("https://docs.google.com/spreadsheets/d/SHEET1/edit")');
  assert.deepEqual(all.map((x) => [x.name, x.rows.length]), [["Budget", 3], ["Q2 & Notes", 2]]);
});

test("googleSlides.read and export; googleDrive.download and export by Drive URL", async () => {
  assert.deepEqual(await s.value('sites.googleSlides.read("https://docs.google.com/presentation/d/DECK1/edit")'), { title: "Roadmap", text: "Roadmap\n\nQ1: ship\nQ2: grow\n" });
  const deck = await s.value('sites.googleSlides.export("https://docs.google.com/presentation/d/DECK1/edit")');
  assert.match(deck.path, /\.pptx$/);
  const file = await s.value('sites.googleDrive.download("https://drive.google.com/file/d/FILE1/view")');
  assert.deepEqual([file.title, file.contentType, fs.readFileSync(file.path, "utf8")], ["report", "application/pdf", "%PDF-1.4 report"]);
  assert.match(file.path, /report-\d+\.pdf$/);
  const viaDrive = await s.value('sites.googleDrive.export({ id: "DOC1", kind: "document" }, { format: "md" })');
  assert.match(fs.readFileSync(viaDrive.path, "utf8"), /^# Design Notes\n\nThe \*\*plan\*\*, in brief\.\n/);
});

test("googleDrive.recent lists the Recent view's files with ids and names", async () => {
  assert.deepEqual(await s.value("sites.googleDrive.recent()"), [
    { id: "1AbCdEfGhIjKlMnOpQrStUvWxYz012345", title: "Design Notes", type: "Google Docs", url: "https://drive.google.com/open?id=1AbCdEfGhIjKlMnOpQrStUvWxYz012345" },
    { id: "1ZyXwVuTsRqPoNmLkJiHgFeDcBa987654", title: "Budget 2026", type: "Google Sheets", url: "https://drive.google.com/open?id=1ZyXwVuTsRqPoNmLkJiHgFeDcBa987654" },
  ]);
});

test("googleDrive.search uses Drive's search (operators such as type:spreadsheet) with the same rows", async () => {
  assert.deepEqual(await s.value('sites.googleDrive.search("type:spreadsheet owner:me")'), [{ id: "1SheetSheetSheetSheetSheetSheet01", title: "Budget 2026", type: "Google Sheets", url: "https://drive.google.com/open?id=1SheetSheetSheetSheetSheetSheet01" }]);
});

test("signed out: Google's sign-in redirect becomes a not_signed_in error naming the fix", async () => {
  const out = await createSitesEnv({ signedIn: false });
  try {
    const err = await out.session("x").error('sites.googleDocs.read("https://docs.google.com/document/d/DOC1/edit")');
    assert.match(err, /Google asked to sign in.*tabs\.open\(\)/);
  } finally {
    await out.close();
  }
});
