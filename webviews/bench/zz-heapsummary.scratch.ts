// Summarize a .heapsnapshot: top classes by self size, big strings with duplicate counts, and retainer chains
// of the largest strings and of the biggest groups.  usage: bun heapsummary.ts FILE.heapsnapshot
import { readFileSync } from "node:fs";

const snap = JSON.parse(readFileSync(process.argv[2]!, "utf8"));
const meta = snap.snapshot.meta;
const nf: string[] = meta.node_fields;
const ef: string[] = meta.edge_fields;
const ntypes: string[] = meta.node_types[0];
const etypes: string[] = meta.edge_types[0];
const N = nf.length, E = ef.length;
const nodes: number[] = snap.nodes, edges: number[] = snap.edges, strings: string[] = snap.strings;
const iType = nf.indexOf("type"), iName = nf.indexOf("name"), iSize = nf.indexOf("self_size"), iEc = nf.indexOf("edge_count");
const eType = ef.indexOf("type"), eName = ef.indexOf("name_or_index"), eTo = ef.indexOf("to_node");
const count = nodes.length / N;
const firstEdge = new Int32Array(count + 1);
for (let i = 0, e = 0; i < count; i++) { firstEdge[i] = e; e += nodes[i * N + iEc]! * E; }
firstEdge[count] = edges.length;
// reverse edges
const retainers: number[][] = Array.from({ length: count }, () => []);
for (let i = 0; i < count; i++)
  for (let e = firstEdge[i]!; e < firstEdge[i + 1]!; e += E) {
    const t = etypes[edges[e + eType]!];
    if (t === "weak") continue;
    retainers[edges[e + eTo]! / N]!.push(i, e);
  }
const type = (i: number) => ntypes[nodes[i * N + iType]!]!;
const name = (i: number) => strings[nodes[i * N + iName]!]!;
const size = (i: number) => nodes[i * N + iSize]!;
const edgeName = (e: number) => {
  const t = etypes[edges[e + eType]!];
  return t === "element" || t === "hidden" ? `[${edges[e + eName]}]` : strings[edges[e + eName]!];
};
let total = 0;
const byClass = new Map<string, { n: number; s: number }>();
for (let i = 0; i < count; i++) {
  total += size(i);
  const t = type(i);
  const k = t === "object" || t === "closure" || t === "native" ? `${t}:${name(i)}` : t;
  const c = byClass.get(k) ?? { n: 0, s: 0 };
  c.n++; c.s += size(i);
  byClass.set(k, c);
}
const mb = (b: number) => (b / 2 ** 20).toFixed(2);
console.log(`total self ${mb(total)} MB, ${count} nodes`);
console.log("== top classes by self size");
for (const [k, c] of [...byClass].sort((a, b) => b[1].s - a[1].s).slice(0, 40)) console.log(`${mb(c.s).padStart(8)} MB ${String(c.n).padStart(8)}  ${k}`);
// strings
const big = new Map<string, { n: number; s: number; ids: number[] }>();
for (let i = 0; i < count; i++) {
  const t = type(i);
  if (t !== "string" && t !== "concatenated string" && t !== "sliced string") continue;
  if (size(i) < 4096) continue;
  const key = `${t} len~${size(i)} ${JSON.stringify(name(i).slice(0, 60))}`;
  const g = big.get(key) ?? { n: 0, s: 0, ids: [] };
  g.n++; g.s += size(i); g.ids.push(i);
  big.set(key, g);
}
console.log("== strings >= 4 KB, grouped (count, total)");
for (const [k, g] of [...big].sort((a, b) => b[1].s - a[1].s).slice(0, 40)) console.log(`${mb(g.s).padStart(8)} MB x${g.n}  ${k}`);
// size histogram of strings
const hist = new Map<string, { n: number; s: number }>();
for (let i = 0; i < count; i++) {
  const t = type(i);
  if (!t.includes("string")) continue;
  const b = size(i) < 64 ? "<64" : size(i) < 1024 ? "<1K" : size(i) < 65536 ? "<64K" : ">=64K";
  const h = hist.get(b) ?? { n: 0, s: 0 }; h.n++; h.s += size(i); hist.set(b, h);
}
console.log("== string size buckets", JSON.stringify([...hist].map(([b, h]) => [b, h.n, mb(h.s)])));
function chain(i: number, depth = 9): string {
  const out: string[] = [];
  const seen = new Set<number>();
  let cur = i;
  for (let d = 0; d < depth; d++) {
    const r = retainers[cur]!;
    if (!r.length) break;
    // prefer a non-system retainer
    let pick = 0;
    for (let k = 0; k < r.length; k += 2) if (!seen.has(r[k]!) && type(r[k]!) !== "hidden" && !name(r[k]!).startsWith("system")) { pick = k; break; }
    const owner = r[pick]!, e = r[pick + 1]!;
    seen.add(owner);
    out.push(`${edgeName(e)} <- ${type(owner)}:${name(owner).slice(0, 40)}(${r.length / 2})`);
    cur = owner;
  }
  return out.join("  ");
}
console.log("== retainer chains of the 25 biggest strings");
const sorted = [...Array(count).keys()].filter((i) => type(i).includes("string")).sort((a, b) => size(b) - size(a)).slice(0, 25);
for (const i of sorted) console.log(`${mb(size(i))} MB ${type(i)} ${JSON.stringify(name(i).slice(0, 40))}\n    ${chain(i)}`);
// sample retainer chains for top object classes
console.log("== sample retainers for top object classes");
for (const [k] of [...byClass].sort((a, b) => b[1].s - a[1].s).slice(0, 15)) {
  let shown = 0;
  for (let i = 0; i < count && shown < 2; i += 997) {
    const t = type(i);
    const kk = t === "object" || t === "closure" || t === "native" ? `${t}:${name(i)}` : t;
    if (kk !== k) continue;
    console.log(`${k}: ${chain(i, 7)}`);
    shown++;
  }
}
// Where the heap sits: each node's self size under its first strong retainer, as `edge <- owner class`, and two levels.
const cls = (i: number) => {
  const t = type(i);
  return t === "object" || t === "closure" || t === "native" ? `${t}:${name(i).slice(0, 40)}` : t;
};
const firstOwner = (i: number): [number, number] | undefined => {
  const r = retainers[i]!;
  for (let k = 0; k < r.length; k += 2) if (type(r[k]!) !== "hidden" || r.length === 2) return [r[k]!, r[k + 1]!];
  return r.length ? [r[0]!, r[1]!] : undefined;
};
const edgeKey = (e: number) => {
  const t = etypes[edges[e + eType]!];
  return t === "element" || t === "hidden" ? "[n]" : String(strings[edges[e + eName]!]).slice(0, 30);
};
const where1 = new Map<string, { n: number; s: number }>();
const where2 = new Map<string, { n: number; s: number }>();
for (let i = 0; i < count; i++) {
  const t = type(i);
  if (t === "code" || t === "hidden" || t === "synthetic") continue;
  if (t === "native" && !name(i).startsWith("system")) continue;
  const a = firstOwner(i);
  if (!a) continue;
  let k1 = `${cls(i)} ${edgeKey(a[1])} <- ${cls(a[0])}`;
  const b = firstOwner(a[0]);
  const k2 = b ? `${k1} ${edgeKey(b[1])} <- ${cls(b[0])}` : k1;
  for (const [m, k] of [[where1, k1], [where2, k2]] as const) {
    const g = m.get(k) ?? { n: 0, s: 0 };
    g.n++; g.s += size(i); m.set(k, g);
  }
}
console.log("== self size by `class edge <- owner`");
for (const [k, g] of [...where1].sort((a, b) => b[1].s - a[1].s).slice(0, 50)) console.log(`${mb(g.s).padStart(8)} MB ${String(g.n).padStart(8)}  ${k}`);
console.log("== two levels");
for (const [k, g] of [...where2].sort((a, b) => b[1].s - a[1].s).slice(0, 60)) console.log(`${mb(g.s).padStart(8)} MB ${String(g.n).padStart(8)}  ${k}`);
console.log("== biggest arrays");
const arrs = [...Array(count).keys()].filter((i) => type(i) === "array").sort((a, b) => size(b) - size(a)).slice(0, 30);
for (const i of arrs) console.log(`${mb(size(i))} MB ${name(i).slice(0, 30)} edges=${(firstEdge[i + 1]! - firstEdge[i]!) / E}\n    ${chain(i, 8)}`);
