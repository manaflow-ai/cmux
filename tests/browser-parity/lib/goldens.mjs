// Builds the expected output for one scenario from reference recordings.
//
//   <scenario>.json             primary reference (Aside or ChatGPT)
//   <scenario>.playwright.json  real Playwright run of the same code (aside dialect)
//   <scenario>.choices.json     {"key": {"source": "playwright"|"aside"|"literal", "value"?, "reason"}}
//
// A key takes the primary reference value unless choices name another source,
// or the primary reference never produced it (it errored first). Reference
// errors are never expected output: cmux must produce every key.
import fs from "node:fs";
import path from "node:path";

const read = (p) => (fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf8")) : null);

export function expectedEmits(dir, name) {
  const primary = read(path.join(dir, `${name}.json`));
  if (!primary) return null;
  const pw = read(path.join(dir, `${name}.playwright.json`)) ?? [];
  const choices = read(path.join(dir, `${name}.choices.json`)) ?? {};
  const clean = (list) => list.filter((e) => e.k !== "__error__" && e.k !== "__unparsed__");
  const p = clean(primary);
  const w = clean(pw);
  const order = (w.length > p.length ? w : p).map((e) => e.k);
  for (const e of [...p, ...w]) if (!order.includes(e.k)) order.push(e.k);
  const byKey = (list) => new Map(list.map((e) => [e.k, e.v]));
  const pm = byKey(p);
  const wm = byKey(w);
  const out = [];
  for (const k of order) {
    const c = choices[k];
    if (c?.source === "literal") out.push({ k, v: c.value });
    else if (c?.source === "playwright" && wm.has(k)) out.push({ k, v: wm.get(k) });
    else if (pm.has(k)) out.push({ k, v: pm.get(k) });
    else if (wm.has(k)) out.push({ k, v: wm.get(k) });
  }
  return out;
}
