import fs from "node:fs";
const s = JSON.parse(fs.readFileSync(process.argv[2]!, "utf8"));
const MINKB = Number(process.argv[3] ?? 300), MAXD = Number(process.argv[4] ?? 10);
const m = s.snapshot.meta; const nf = m.node_fields; const F = nf.length; const ef = m.edge_fields; const E = ef.length;
const ti = nf.indexOf("type"), ni = nf.indexOf("name"), si = nf.indexOf("self_size"), eci = nf.indexOf("edge_count");
const types = m.node_types[0]; const etypes = m.edge_types[0];
const nodes: number[] = s.nodes, edges: number[] = s.edges, strings: string[] = s.strings;
const N = nodes.length / F;
const firstEdge = new Int32Array(N + 1);
for (let i = 0, e = 0; i < N; i++) { firstEdge[i] = e; e += nodes[i * F + eci] * E; } firstEdge[N] = edges.length;
const weak = etypes.indexOf("weak");
const succ = (v: number, f: (w: number, e: number) => void) => { for (let e = firstEdge[v]; e < firstEdge[v + 1]; e += E) { if (edges[e] === weak) continue; f(edges[e + 2] / F, e); } };
// iterative DFS from root 0
const order = new Int32Array(N).fill(-1), vertex = new Int32Array(N), parent = new Int32Array(N);
let cnt = 0; const stack: number[] = [0]; const estack: number[] = [firstEdge[0]]; order[0] = cnt; vertex[cnt++] = 0;
while (stack.length) { const v = stack[stack.length - 1]; let e = estack[estack.length - 1]; let pushed = false;
  while (e < firstEdge[v + 1]) { const t = edges[e]; const w = edges[e + 2] / F; e += E; if (t === weak) continue; if (order[w] < 0) { order[w] = cnt; vertex[cnt++] = w; parent[w] = v; estack[estack.length - 1] = e; stack.push(w); estack.push(firstEdge[w]); pushed = true; break; } }
  if (!pushed) { stack.pop(); estack.pop(); } }
// preds
const predCount = new Int32Array(N);
for (let v = 0; v < N; v++) if (order[v] >= 0) succ(v, (w) => { if (order[w] >= 0) predCount[w]++; });
const predStart = new Int32Array(N + 1); for (let v = 0; v < N; v++) predStart[v + 1] = predStart[v] + predCount[v];
const preds = new Int32Array(predStart[N]); const fill = predStart.slice(0, N);
for (let v = 0; v < N; v++) if (order[v] >= 0) succ(v, (w) => { if (order[w] >= 0) preds[fill[w]++] = v; });
// Lengauer-Tarjan (simple) on dfs numbers
const semi = new Int32Array(cnt), idom = new Int32Array(cnt), anc = new Int32Array(cnt).fill(-1), label = new Int32Array(cnt);
for (let i = 0; i < cnt; i++) { semi[i] = i; label[i] = i; }
const bucket: number[][] = Array.from({ length: cnt }, () => []);
const evalv = (v: number) => { if (anc[v] < 0) return v; // compress iteratively
  const path: number[] = []; let x = v; while (anc[anc[x]] >= 0) { path.push(x); x = anc[x]; }
  for (let i = path.length - 1; i >= 0; i--) { const y = path[i]; if (semi[label[anc[y]]] < semi[label[y]]) label[y] = label[anc[y]]; anc[y] = anc[anc[y]]; }
  return label[v]; };
for (let i = cnt - 1; i > 0; i--) { const w = vertex[i];
  for (let p = predStart[w]; p < predStart[w + 1]; p++) { const u = evalv(order[preds[p]]); if (semi[u] < semi[i]) semi[i] = semi[u]; }
  bucket[semi[i]].push(i); const pi = order[parent[w]]; anc[i] = pi;
  for (const v of bucket[pi]) { const u = evalv(v); idom[v] = semi[u] < semi[v] ? u : pi; } bucket[pi] = []; }
for (let i = 1; i < cnt; i++) if (idom[i] !== semi[i]) idom[i] = idom[idom[i]];
const ret = new Float64Array(cnt); for (let i = 0; i < cnt; i++) ret[i] = nodes[vertex[i] * F + si];
for (let i = cnt - 1; i > 0; i--) ret[idom[i]] += ret[i];
const kids: number[][] = Array.from({ length: cnt }, () => []); for (let i = 1; i < cnt; i++) kids[idom[i]].push(i);
const lbl = (i: number) => { const v = vertex[i]; return `${types[nodes[v * F + ti]]}:${String(strings[nodes[v * F + ni]]).slice(0, 70).replace(/\n/g, " ")}`; };
const edgeName = (pi: number, i: number) => { const p = vertex[pi], c = vertex[i]; let nm = "?"; for (let e = firstEdge[p]; e < firstEdge[p + 1]; e += E) if (edges[e + 2] / F === c) { const t = etypes[edges[e]]; nm = t === "element" || t === "hidden" ? `[${edges[e + 1]}]` : String(strings[edges[e + 1]]); break; } return nm; };
const out: string[] = [];
const walk = (i: number, d: number) => { for (const k of kids[i].sort((a, b) => ret[b] - ret[a])) { if (ret[k] < MINKB * 1024) break; out.push(`${"  ".repeat(d)}${(ret[k] / 1048576).toFixed(2)}MB .${edgeName(i, k)} -> ${lbl(k)}`); if (d < MAXD) walk(k, d + 1); } };
walk(0, 0);
console.log(`total ${(ret[0] / 1048576).toFixed(1)} MB`); console.log(out.join("\n"));
// aggregate root's grandchildren (under GC roots synthetic) by label
if (process.argv[5]) {
  const agg = new Map<string, number>();
  const visit = (i: number, d: number) => { for (const k of kids[i]) { if (d >= 1) { const l = lbl(k).replace(/@\d+/, "").replace(/:\d+\//, "/"); agg.set(l, (agg.get(l) ?? 0) + ret[k]); } else visit(k, d + 1); } };
  visit(0, 0);
  fs.writeFileSync(process.argv[5], JSON.stringify([...agg].map(([k, v]) => [k, [v, 1]])));
}
