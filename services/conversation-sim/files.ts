// Procedural documents that bots send: a one-page PDF, a ZIP archive and a
// plain text file. Each is generated from its id, so it is stable across
// requests without being stored.
import { mulberry32 } from "./png";
import type { Rng } from "./corpus";

export type FileKind = "pdf" | "zip" | "txt";
export const FILE_KINDS: FileKind[] = ["pdf", "zip", "txt"];

export interface FileMeta {
  name: string;
  mime: string;
  ext: string;
}

const NAMES: Record<FileKind, string[]> = {
  pdf: ["Quarterly Report", "Design Review", "Launch Checklist", "Invoice 2026-10", "Floor Plan"],
  zip: ["build-logs", "screenshots", "crash-reports", "assets", "release-notes"],
  txt: ["notes", "todo", "meeting-minutes", "packing-list", "ideas"],
};
const MIME: Record<FileKind, string> = { pdf: "application/pdf", zip: "application/zip", txt: "text/plain" };

export function fileMeta(kind: FileKind, rng: Rng): FileMeta {
  const names = NAMES[kind];
  const name = names[Math.floor(rng() * names.length)];
  return { name: `${name}.${kind}`, mime: MIME[kind], ext: kind };
}

function seedOf(id: string): number {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) h = Math.imul(h ^ id.charCodeAt(i), 16777619);
  return h >>> 0;
}

const LINES = [
  "Revenue grew in every region this quarter.",
  "Ship the reconnect backoff fix before Friday.",
  "The new split resize feels much better.",
  "Remember to update the changelog.",
  "Latency is down 40% since the relay change.",
  "Two open questions remain for design review.",
];

function textBody(id: string, lines: number): string {
  const rng = mulberry32(seedOf(id));
  const out: string[] = [];
  for (let i = 0; i < lines; i++) out.push(`${i + 1}. ${LINES[Math.floor(rng() * LINES.length)]}`);
  return out.join("\n") + "\n";
}

/** A valid single-page PDF with a title and a few lines of text. */
function pdfBytes(id: string, title: string): Uint8Array {
  const body = textBody(id, 12).split("\n").filter(Boolean);
  const esc = (s: string) => s.replace(/[\\()]/g, (c) => "\\" + c);
  let stream = "BT /F1 28 Tf 72 720 Td (" + esc(title) + ") Tj ET\n";
  body.forEach((line, i) => (stream += `BT /F1 13 Tf 72 ${670 - i * 22} Td (${esc(line)}) Tj ET\n`));
  stream += "0.04 0.52 1 rg 72 120 468 90 re f\n";
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    `<< /Length ${stream.length} >>\nstream\n${stream}endstream`,
  ];
  let pdf = "%PDF-1.4\n";
  const offsets: number[] = [];
  objects.forEach((o, i) => {
    offsets.push(pdf.length);
    pdf += `${i + 1} 0 obj\n${o}\nendobj\n`;
  });
  const xref = pdf.length;
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const off of offsets) pdf += `${String(off).padStart(10, "0")} 00000 n \n`;
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return new TextEncoder().encode(pdf);
}

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** A stored (uncompressed) ZIP holding `entries`. */
export function zipBytes(entries: { name: string; data: Uint8Array }[]): Uint8Array {
  const parts: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;
  for (const e of entries) {
    const name = new TextEncoder().encode(e.name);
    const crc = crc32(e.data);
    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(4, 20, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, e.data.length, true);
    local.setUint32(22, e.data.length, true);
    local.setUint16(26, name.length, true);
    parts.push(new Uint8Array(local.buffer), name, e.data);
    const dir = new DataView(new ArrayBuffer(46));
    dir.setUint32(0, 0x02014b50, true);
    dir.setUint16(4, 20, true);
    dir.setUint16(6, 20, true);
    dir.setUint32(16, crc, true);
    dir.setUint32(20, e.data.length, true);
    dir.setUint32(24, e.data.length, true);
    dir.setUint16(28, name.length, true);
    dir.setUint32(42, offset, true);
    central.push(new Uint8Array(dir.buffer), name);
    offset += 30 + name.length + e.data.length;
  }
  const centralSize = central.reduce((n, p) => n + p.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, entries.length, true);
  end.setUint16(10, entries.length, true);
  end.setUint32(12, centralSize, true);
  end.setUint32(16, offset, true);
  const all = [...parts, ...central, new Uint8Array(end.buffer)];
  const out = new Uint8Array(all.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of all) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** The bytes of a procedural document `id` named `name`. */
export function proceduralFile(id: string, name: string): Uint8Array {
  const ext = name.split(".").pop()?.toLowerCase();
  if (ext === "pdf") return pdfBytes(id, name.replace(/\.pdf$/i, ""));
  if (ext === "zip") {
    const enc = new TextEncoder();
    return zipBytes([
      { name: "README.txt", data: enc.encode(textBody(id + "r", 6)) },
      { name: "log.txt", data: enc.encode(textBody(id + "l", 40)) },
    ]);
  }
  return new TextEncoder().encode(textBody(id, 30));
}
