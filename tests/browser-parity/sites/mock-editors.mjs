// Mock Google Docs, Sheets and Slides editors and their exports, for the
// editing tools. Each file lives in `files` (shared with the test): the
// editors change it through the UI the tools drive (name box, paste,
// Delete, Find and replace, title, File > Move to trash) and the export
// endpoints read it back (CSV, HTML, xlsx and pptx built as real zip files).
import zlib from "node:zlib";

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// A minimal zip writer (deflate), enough for xlsx and pptx exports.
export function zip(entries) {
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc32 = (buf) => {
    let c = 0xffffffff;
    for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const [name, text] of entries) {
    const data = Buffer.from(text);
    const comp = zlib.deflateRawSync(data);
    const nameBuf = Buffer.from(name);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(8, 8);
    local.writeUInt32LE(crc32(data), 14);
    local.writeUInt32LE(comp.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(8, 10);
    central.writeUInt32LE(crc32(data), 16);
    central.writeUInt32LE(comp.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, nameBuf, comp);
    centrals.push(central, nameBuf);
    offset += 30 + nameBuf.length + comp.length;
  }
  const cd = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}

const colName = (c) => {
  let s = "";
  for (c += 1; c > 0; c = Math.floor((c - 1) / 26)) s = String.fromCharCode(65 + ((c - 1) % 26)) + s;
  return s;
};
const parseRef = (ref) => {
  const m = /^([A-Z]+)(\d+)$/.exec(ref.toUpperCase());
  return { c: [...m[1]].reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1, r: Number(m[2]) - 1 };
};
const rangeCells = (range) => {
  const [a, b] = range.toUpperCase().split(":");
  const p = parseRef(a);
  const q = parseRef(b || a);
  const out = [];
  for (let r = p.r; r <= q.r; r++) for (let c = p.c; c <= q.c; c++) out.push({ r, c });
  return { start: p, cells: out };
};

// A sheet is { name, gid, cells: Map("A1" -> raw string, "=..." for formulas) }.
const evalCell = (sheet, raw) => {
  if (typeof raw !== "string" || !raw.startsWith("=")) return raw;
  const m = /^=SUM\(([A-Z]+\d+):([A-Z]+\d+)\)$/i.exec(raw);
  if (m) return String(rangeCells(`${m[1]}:${m[2]}`).cells.reduce((n, { r, c }) => n + (Number(evalCell(sheet, sheet.cells.get(colName(c) + (r + 1)))) || 0), 0));
  return "#ERROR!";
};
const sheetRows = (sheet) => {
  let maxR = -1;
  let maxC = -1;
  for (const ref of sheet.cells.keys()) {
    const { r, c } = parseRef(ref);
    maxR = Math.max(maxR, r);
    maxC = Math.max(maxC, c);
  }
  const rows = [];
  for (let r = 0; r <= maxR; r++) {
    const row = [];
    for (let c = 0; c <= maxC; c++) row.push(evalCell(sheet, sheet.cells.get(colName(c) + (r + 1)) ?? ""));
    rows.push(row);
  }
  return rows;
};
const csv = (rows) => rows.map((r) => r.map((v) => (/[",\n]/.test(v) ? `"${String(v).replace(/"/g, '""')}"` : v)).join(",")).join("\n") + (rows.length ? "\n" : "");

function xlsx(file) {
  const strings = [];
  const si = (s) => {
    let i = strings.indexOf(s);
    if (i < 0) i = strings.push(s) - 1;
    return i;
  };
  const sheetXml = file.sheets.map((sheet) => {
    const rows = new Map();
    for (const [ref, raw] of sheet.cells) {
      const { r } = parseRef(ref);
      if (!rows.has(r)) rows.set(r, []);
      const value = evalCell(sheet, raw);
      // As Google writes them: whole numbers with ".0".
      const num = (x) => (/^-?\d+$/.test(x) ? x + ".0" : x);
      const cell = typeof raw === "string" && raw.startsWith("=") ? `<c r="${ref}"><f>${esc(raw.slice(1))}</f><v>${esc(num(value))}</v></c>` : /^-?\d+(\.\d+)?$/.test(raw) ? `<c r="${ref}"><v>${num(raw)}</v></c>` : `<c r="${ref}" t="s"><v>${si(raw)}</v></c>`;
      rows.get(r).push(cell);
    }
    const body = [...rows.entries()].sort((a, b) => a[0] - b[0]).map(([r, cells]) => `<row r="${r + 1}">${cells.join("")}</row>`).join("");
    return `<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>${body}</sheetData></worksheet>`;
  });
  return zip([
    ["[Content_Types].xml", "<Types/>"],
    ["xl/workbook.xml", `<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${file.sheets.map((s, i) => `<sheet name="${esc(s.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("")}</sheets></workbook>`],
    ["xl/_rels/workbook.xml.rels", `<Relationships>${file.sheets.map((s, i) => `<Relationship Id="rId${i + 1}" Target="worksheets/sheet${i + 1}.xml" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"/>`).join("")}</Relationships>`],
    ...sheetXml.map((x, i) => [`xl/worksheets/sheet${i + 1}.xml`, x]),
    ["xl/sharedStrings.xml", `<sst>${strings.map((s) => `<si><t>${esc(s)}</t></si>`).join("")}</sst>`],
  ]);
}

function pptx(file) {
  const para = (t) => `<a:p><a:r><a:t>${esc(t)}</a:t></a:r></a:p>`;
  const entries = [["[Content_Types].xml", "<Types/>"]];
  file.slides.forEach((s, i) => {
    entries.push([`ppt/slides/slide${i + 1}.xml`, `<p:sld><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody>${para(s.title)}</p:txBody></p:sp><p:sp><p:txBody>${s.body.map(para).join("")}</p:txBody></p:sp></p:spTree></p:cSld></p:sld>`]);
    entries.push([`ppt/slides/_rels/slide${i + 1}.xml.rels`, `<Relationships><Relationship Id="rId2" Target="../notesSlides/notesSlide${i + 1}.xml"/></Relationships>`]);
    entries.push([`ppt/notesSlides/notesSlide${i + 1}.xml`, `<p:notes><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody>${para(s.notes)}</p:txBody></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph type="sldNum"/></p:nvPr></p:nvSpPr><p:txBody>${para(String(i + 1))}</p:txBody></p:sp></p:spTree></p:cSld></p:notes>`]);
  });
  return zip(entries);
}

const docText = (file) => file.blocks.map((b) => (b.type === "table" ? b.rows.map((r) => r.join("\t")).join("\n") : b.type === "list" ? b.items.map((x) => "* " + x).join("\n") : b.text)).join("\n");
function docHtml(file) {
  const body = file.blocks
    .map((b) => {
      if (b.type === "heading") return `<h${b.level} id="h.${b.level}x" class="c3"><span class="c1">${esc(b.text)}</span></h${b.level}>`;
      if (b.type === "table") return `<table class="c5"><tbody>${b.rows.map((r) => `<tr class="c2">${r.map((c) => `<td class="c4" colspan="1" rowspan="1"><p class="c0"><span class="c1">${esc(c)}</span></p></td>`).join("")}</tr>`).join("")}</tbody></table>`;
      if (b.type === "list") return `<ul class="lst-kix_1-0 start">${b.items.map((x) => `<li class="c0 li-bullet-0"><span class="c1">${esc(x)}</span></li>`).join("")}</ul>`;
      return `<p class="c0"><span class="c1">${esc(b.text)}</span></p>`;
    })
    .join("");
  return `<html><head><meta content="text/html; charset=UTF-8" http-equiv="content-type"><style type="text/css">.c1{color:#000}</style></head><body class="c6 doc-content">${body}<p class="c0 c7"><span class="c1"></span></p></body></html>`;
}

// Find and replace on plain text blocks (headings, paragraphs, list items).
function replaceIn(file, find, repl) {
  let n = 0;
  const swap = (s) => s.split(find).length - 1;
  for (const b of file.blocks || []) {
    if (b.text !== undefined) (n += swap(b.text)), (b.text = b.text.split(find).join(repl));
    if (b.items) b.items = b.items.map((x) => ((n += swap(x)), x.split(find).join(repl)));
  }
  for (const s of file.slides || []) {
    n += swap(s.title) + s.body.reduce((k, x) => k + swap(x), 0);
    s.title = s.title.split(find).join(repl);
    s.body = s.body.map((x) => x.split(find).join(repl));
  }
  return n;
}

const shell = (file, body) => `<!doctype html><html><head><meta charset="utf-8"><title>${esc(file.title)} - Google ${file.kind === "spreadsheets" ? "Sheets" : file.kind === "document" ? "Docs" : "Slides"}</title></head><body>${file.trashed ? '<div role="alert">File is in trash</div>' : ""}
<div id="docs-titlebar"><input class="docs-title-input" value="${esc(file.title)}" aria-label="Rename">
<div id="share-slot"></div><div role="button" aria-label="Share screen">Present</div>
<div id="docs-file-menu" role="menuitem">File</div><div id="docs-edit-menu" role="menuitem">Edit</div></div>
${body}
<script>
// As in the editors: the Share button (no id) renders a moment after the title.
// As live: an unlabeled wrapper carries the id; the inner button the label.
setTimeout(() => { document.getElementById("share-slot").innerHTML = '<div id="docs-titlebar-share-client-button">${file.decoyShare === "inside" ? '<span aria-label="Share. Private to only me. "></span>' : ""}<div role="button" aria-label="Share. ${esc(file.shareText || (file.shared ? "Anyone with the link can view" : "Private to only me"))}. "> <span>Share</span></div></div>'; }, 600);
// decoyShare: a script (or another session) puts a label that says
// private where the old reader looked: anywhere in the page before the
// button ("page"), or a second label inside the button ("inside").
${file.decoyShare === "page" ? `document.getElementById("docs-titlebar").insertAdjacentHTML("afterbegin", '<div aria-label="Share. Private to only me. "></div>');` : ""}
const post = (path, data) => fetch(location.pathname.replace(/\\/edit$/, "") + "/__mock/" + path, { method: "POST", body: JSON.stringify(data) });
// As live in Docs: a rename typed while the editor is still loading is lost.
const loadedAt = Date.now();
document.querySelector(".docs-title-input").addEventListener("keydown", (e) => {
  if (e.key !== "Enter") return;
  if (Date.now() - loadedAt < 1200) { e.target.value = document.title.replace(/ - Google \\w+$/, ""); return; }
  post("title", { title: e.target.value });
  document.title = e.target.value + " - Google Docs";
});
document.getElementById("docs-file-menu").addEventListener("click", () => {
  document.body.insertAdjacentHTML("beforeend", '<div role="menu"><div role="menuitem" id="trash-item">Move to trash</div></div>');
  document.getElementById("trash-item").addEventListener("click", async () => { await post("trash", {}); document.body.insertAdjacentHTML("beforeend", '<div role="dialog">File moved to trash</div>'); });
});
// Find and replace: Meta+Shift+H, or Edit > Find and replace. As live, the
// Slides shortcut does nothing while the filmstrip has focus (a new tab).
const openFind = () => {
  if (!document.querySelector(".docs-findandreplacedialog")) {
    document.body.insertAdjacentHTML("beforeend", '<div role="dialog" class="docs-findandreplacedialog"><input aria-label="Find" class="docs-findandreplacedialog-input"><input aria-label="Replace with" class="docs-findandreplacedialog-replace-input"><button>Replace</button><button>Replace all</button><button aria-label="Close">x</button></div>');
    const d = document.querySelector(".docs-findandreplacedialog");
    d.querySelector("input").focus();
    d.querySelectorAll("button")[1].addEventListener("click", async () => {
      const r = await (await post("replace", { find: d.querySelector(".docs-findandreplacedialog-input").value, replace: d.querySelector(".docs-findandreplacedialog-replace-input").value })).json();
      d.insertAdjacentHTML("beforeend", '<div class="status">Replaced ' + r.count + ' occurrences</div>');
    });
    d.querySelector('[aria-label="Close"]').addEventListener("click", () => d.remove());
  }
};
document.addEventListener("keydown", (e) => {
  if (e.metaKey && e.shiftKey && e.key.toLowerCase() === "h" && ${JSON.stringify(file.kind)} !== "presentation") openFind();
});
document.getElementById("docs-edit-menu").addEventListener("click", () => {
  document.body.insertAdjacentHTML("beforeend", '<div role="menu"><div role="menuitem" id="find-item">Find and replace⌘+Shift+H</div></div>');
  document.getElementById("find-item").addEventListener("click", () => { document.querySelectorAll('[role="menu"]').forEach((m) => m.remove()); openFind(); });
});
</script></body></html>`;

function sheetEditor(file) {
  return shell(
    file,
    `<div id="docs-save-indicator-badge"><span id="save-badge">Saved to Drive</span></div><div id="waffle-grid-container"><input id="t-name-box" aria-label="Name Box" value="A1"><div class="cell-input" contenteditable="true" tabindex="0"></div></div>
<script>
let range = "A1";
let cur = null;
let buf = "";
const box = document.getElementById("t-name-box");
const cell = document.querySelector(".cell-input");
const ref = (r, c) => { let s = ""; for (c += 1; c > 0; c = Math.floor((c - 1) / 26)) s = String.fromCharCode(65 + ((c - 1) % 26)) + s; return s + (r + 1); };
box.addEventListener("keydown", (e) => {
  if (e.key !== "Enter") return;
  e.preventDefault();
  range = box.value.toUpperCase();
  const m = /^([A-Z]+)(\\d+)/.exec(range);
  const c = [...m[1]].reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1;
  cur = { r: Number(m[2]) - 1, c, start: c };
  cell.textContent = "";
  cell.focus();
});
const saving = () => { const b = document.getElementById("save-badge"); b.textContent = "Saving…"; setTimeout(() => (b.textContent = "Saved to Drive"), 1000); };
const commit = () => { if (buf !== "" && cur) { saving(); post("cells", { range: ref(cur.r, cur.c), tsv: buf, via: "typed" }); } buf = ""; };
// As live in WebKit: typed keys edit the cell; text inserted without a
// keydown or a composition does not reach Sheets' cell editor; a paste is
// read from its clipboardData as TSV at the selected cell. A file with
// ignorePaste models an editor that drops pastes, for the typed fallback.
cell.addEventListener("beforeinput", (e) => {
  e.preventDefault();
  if (e.inputType === "insertText" && e.data && e.data.length === 1) buf += e.data;
});
cell.addEventListener("paste", (e) => {
  e.preventDefault();
  const tsv = e.clipboardData ? e.clipboardData.getData("text/plain") : "";
  if (${JSON.stringify(!!file.ignorePaste)} || !tsv || !cur) return;
  saving();
  post("cells", { range: ref(cur.r, cur.c), tsv, via: "paste" });
});
cell.addEventListener("keydown", (e) => {
  if (e.key === "Tab") { e.preventDefault(); commit(); cur.c++; }
  else if (e.key === "Enter") { e.preventDefault(); commit(); cur.r++; cur.c = cur.start; }
});
cell.addEventListener("keydown", (e) => { if (e.key === "Delete" || e.key === "Backspace") { saving(); post("clear", { range }); } });
</script>`,
  );
}

export function createEditors() {
  const files = new Map();
  let next = 1;
  const add = (file) => {
    const id = file.id || `1mock${String(next++).padStart(4, "0")}${"x".repeat(24)}`;
    files.set(id, { ...file, id, trashed: false });
    return id;
  };
  // Fixtures: one shared sheet, one private doc and deck.
  add({ id: "1sheetSHARED00000000000000000000x", kind: "spreadsheets", title: "Team budget", shared: true, sheets: [{ name: "Budget", gid: "0", cells: new Map([["A1", "Item"], ["B1", "Cost"], ["A2", "Rent"], ["B2", "1200"], ["A3", "Food"], ["B3", "300"], ["A4", "Total"], ["B4", "=SUM(B2:B3)"]]) }, { name: "Notes", gid: "7", cells: new Map([["A1", "remember"]]) }] });
  add({ id: "1docPRIVATE000000000000000000000x", kind: "document", title: "Plan", shared: false, blocks: [{ type: "heading", level: 1, text: "Plan" }, { type: "paragraph", text: "Intro paragraph." }, { type: "heading", level: 2, text: "Goals" }, { type: "list", items: ["Ship it", "Measure it"] }, { type: "table", rows: [["Owner", "Task"], ["Ada", "Draft"]] }, { type: "paragraph", text: "Closing line." }] });
  add({ id: "1deckPRIVATE00000000000000000000x", kind: "presentation", title: "Roadmap deck", shared: false, slides: [{ id: "g1a2b3c_0_0", title: "Roadmap", body: ["Q1: ship", "Q2: grow"], notes: "Say hello" }, { id: "g1a2b3c_0_7", title: "Risks", body: ["Time"], notes: "Keep short" }] });

  function handle(req, url, body, internal = {}) {
    if (req.method === "GET" && /^\/(document|spreadsheets|presentation)\/create$/.test(url.pathname)) {
      const kind = url.pathname.split("/")[1];
      const id = add({ kind, owner: internal.owner || null, title: kind === "document" ? "Untitled document" : kind === "spreadsheets" ? "Untitled spreadsheet" : "Untitled presentation", shared: false, sheets: [{ name: "Sheet1", gid: "0", cells: new Map() }], blocks: [{ type: "paragraph", text: "" }], slides: [{ title: "", body: [], notes: "" }] });
      return { redirect: `https://docs.google.com/${kind}/d/${id}/edit` };
    }
    const m = /^\/(document|spreadsheets|presentation)\/d\/([\w-]+)\/(edit|export|htmlview|__mock\/(\w+))$/.exec(url.pathname);
    if (!m) return null;
    const file = files.get(m[2]);
    // Files the editors do not hold are the other mock fixtures'.
    if (!file) return null;
    if (file.kind !== m[1]) return { status: 404, html: "<p>Not found</p>" };
    const op = m[3];
    if (op === "edit") {
      // A collaborator shares the file right after an editor page loaded
      // (its Share button still shows the old label).
      if (file.shareAfterEditorLoad && !internal.skipShare) {
        const page = handle(req, url, body, { skipShare: true });
        (file.shared = true), (file.shareAfterEditorLoad = false);
        return page;
      }
      if (file.kind === "spreadsheets") return { html: sheetEditor(file) };
      if (file.kind === "document")
        return {
          html: shell(
            file,
            `<div class="kix-appview-editor" role="textbox" aria-label="Document content" contenteditable="true">${esc(docText(file))}</div>
<script>
// Typed text (after the tool moves to the end and starts a paragraph) becomes a new paragraph.
let typed = "", timer = null;
document.querySelector(".kix-appview-editor").addEventListener("input", (e) => {
  if (e.inputType !== "insertText" || !e.data) return;
  typed += e.data;
  clearTimeout(timer);
  timer = setTimeout(() => { post("append", { text: typed }); typed = ""; }, 200);
});
</script>`,
          ),
        };
      return {
        html: shell(
          file,
          `<svg id="filmstrip" width="200" height="${file.slides.length * 110}">${file.slides.map((s, i) => `<g id="filmstrip-slide-${i}-${s.id || `p${i}`}"><rect x="10" y="${i * 110 + 5}" width="150" height="90" fill="#eee"></rect></g>`).join("")}</svg>
<div class="punch-viewer-svgpage">${esc(file.slides.map((s) => s.title).join(" "))}</div>
<div id="speakernotes"><div id="speakernotes-workspace" role="textbox" aria-label="Speaker notes" tabindex="0" style="min-height:40px"></div></div>
<script>
// As live: thumbnails g#filmstrip-slide-<i>-<pageId> select a slide (the
// page id is the slide's object id and stays with it when slides move); the
// notes textbox takes typed keys (Meta+A selects all notes; Escape commits).
let slide = 0, notes = null, replaceAll = false, atStart = false;
document.querySelectorAll("#filmstrip g").forEach((g, i) => g.addEventListener("click", () => { slide = i; }));
const nw = document.getElementById("speakernotes-workspace");
nw.addEventListener("click", () => { nw.focus(); notes = ""; replaceAll = false; atStart = false; });
nw.addEventListener("keydown", (e) => {
  // As live: Meta+A does not select the notes; Meta+ArrowUp then Meta+Shift+ArrowDown does.
  if (e.metaKey && e.key.toLowerCase() === "a") { e.preventDefault(); return; }
  if (e.metaKey && !e.shiftKey && e.key === "ArrowUp") { e.preventDefault(); atStart = true; return; }
  if (e.metaKey && e.shiftKey && e.key === "ArrowDown") { e.preventDefault(); if (atStart) replaceAll = true; return; }
  if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); return; }
  if (e.key === "Enter") { e.preventDefault(); notes += "\\n"; return; }
  if (e.key === "Escape") { if (notes !== null) post("notes", { index: slide, text: notes, replaceAll }); notes = null; return; }
  if (e.key.length === 1 && !e.metaKey) { e.preventDefault(); notes += e.key; }
});
</script>`,
        ),
      };
    }
    if (op === "htmlview" && file.kind === "spreadsheets") return { html: `<html><head><title>${esc(file.title)} - Google Sheets</title></head><body><ul>${file.sheets.map((s) => `<li id="sheet-button-${s.gid}"><a href="#">${esc(s.name)}</a></li>`).join("")}</ul></body></html>` };
    if (op === "export") {
      // As live: Google answers 429 to exports requested in quick succession.
      const now = Date.now();
      const last = file.lastExport || 0;
      file.lastExport = now;
      if (now - last < 1500) return { status: 429, text: "Too Many Requests" };
      const format = url.searchParams.get("format");
      const attach = (name, type, data) => ({ status: 200, headers: { "content-type": type, "content-disposition": `attachment; filename="${name}"` }, body: data });
      if (file.kind === "spreadsheets") {
        // Binary exports redirect to a googleusercontent host without CORS headers.
        if (format === "xlsx") return { redirect: `https://doc-export.googleusercontent.com/export/${file.id}?format=xlsx` };
        const sheet = file.sheets.find((s) => s.gid === (url.searchParams.get("gid") || "0"));
        if (format === "csv") return attach(`${file.title} - ${sheet.name}.csv`, "text/csv", csv(sheetRows(sheet)));
      }
      if (file.kind === "document") {
        if (format === "html") return attach(`${file.title}.html`, "text/html", docHtml(file));
        if (format === "txt") return attach(`${file.title}.txt`, "text/plain", docText(file) + "\n");
        if (format === "md") return attach(`${file.title}.md`, "text/markdown", docText(file) + "\n");
      }
      if (file.kind === "presentation") {
        if (format === "pptx") return { redirect: `https://doc-export.googleusercontent.com/export/${file.id}?format=pptx` };
        if (format === "txt") return attach(`${file.title}.txt`, "text/plain", file.slides.map((s) => [s.title, ...s.body].join("\n")).join("\n\n"));
      }
      return { status: 400, text: "bad format" };
    }
    const data = JSON.parse(body || "{}");
    const action = m[4];
    // Cell edits reach the saved file (what exports read) 800 ms later.
    if (action === "cells" || action === "clear") {
      if (data.via) (file.edits ||= []).push(data.via);
      setTimeout(() => apply(file, action, data), 800);
      return { json: { ok: true } };
    }
    if (action === "title") file.title = data.title;
    if (action === "trash") file.trashed = true;
    if (action === "append") file.blocks.push({ type: "paragraph", text: data.text });
    if (action === "notes") file.slides[data.index].notes = data.replaceAll ? data.text : file.slides[data.index].notes + data.text;
    if (action === "replace") return { json: { count: replaceIn(file, data.find, data.replace) } };
    return { json: { ok: true } };
  }
  function apply(file, action, data) {
    {
      const sheet = file.sheets[0];
      const { start, cells } = rangeCells(data.range);
      if (action === "clear") for (const { r, c } of cells) sheet.cells.delete(colName(c) + (r + 1));
      else
        data.tsv.replace(/\n$/, "").split("\n").forEach((line, dr) => line.split("\t").forEach((v, dc) => {
          const ref = colName(start.c + dc) + (start.r + dr + 1);
          if (v === "") sheet.cells.delete(ref);
          else sheet.cells.set(ref, v);
        }));
    }
  }
  // The googleusercontent host that serves binary exports (no CORS headers).
  function exportHost(req, url) {
    const file = files.get(url.pathname.split("/").pop());
    if (!file || file.trashed) return { status: 404, text: "" };
    const format = url.searchParams.get("format");
    const type = format === "xlsx" ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "application/vnd.openxmlformats-officedocument.presentationml.presentation";
    return { status: 200, headers: { "content-type": type, "content-disposition": `attachment; filename="${file.title}.${format}"` }, body: format === "xlsx" ? xlsx(file) : pptx(file) };
  }
  return { files, handle, add, exportHost };
}
