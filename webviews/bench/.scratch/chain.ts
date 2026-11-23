import fs from "node:fs";
const s = JSON.parse(fs.readFileSync(process.argv[2]!, "utf8"));
const m = s.snapshot.meta;
const nf = m.node_fields;
const F = nf.length;
const E = m.edge_fields.length;
const ti = nf.indexOf("type"),
  ni = nf.indexOf("name"),
  si = nf.indexOf("self_size"),
  eci = nf.indexOf("edge_count");
const types = m.node_types[0];
const etypes = m.edge_types[0];
const nodes: number[] = s.nodes,
  edges: number[] = s.edges,
  strings: string[] = s.strings;
const N = nodes.length / F;
const fe = new Int32Array(N + 1);
for (let i = 0, e = 0; i < N; i++) {
  fe[i] = e;
  e += nodes[i * F + eci] * E;
}
fe[N] = edges.length;
const props = (v: number) => {
  const o: [string, number, string][] = [];
  for (let e = fe[v]; e < fe[v + 1]; e += E) {
    const t = etypes[edges[e]];
    const nm = t === "element" || t === "hidden" ? `[${edges[e + 1]}]` : String(strings[edges[e + 1]]);
    const w = edges[e + 2] / F;
    o.push([nm, w, `${types[nodes[w * F + ti]]}:${String(strings[nodes[w * F + ni]]).slice(0, 80)}`]);
  }
  return o;
};
// find objects with a 'next' prop chain length > 1000
const nextOf = (v: number) => {
  for (let e = fe[v]; e < fe[v + 1]; e += E)
    if (etypes[edges[e]] === "property" && strings[edges[e + 1]] === "next") return edges[e + 2] / F;
  return -1;
};
const hasIncomingNext = new Uint8Array(N);
for (let v = 0; v < N; v++) {
  const w = nextOf(v);
  if (w >= 0) hasIncomingNext[w] = 1;
}
let shown = 0;
for (let v = 0; v < N && shown < 3; v++) {
  if (hasIncomingNext[v] || nextOf(v) < 0) continue;
  let len = 0,
    x = v;
  const seen = new Set<number>();
  while (x >= 0 && !seen.has(x)) {
    seen.add(x);
    len++;
    x = nextOf(x);
  }
  if (len < 500) continue;
  shown++;
  console.log(`chain len ${len} from node ${v}; props of head:`);
  for (const p of props(v).slice(0, 25)) console.log("   ", p[0], "->", p[2]);
  const mid = [...seen][Math.floor(len / 2)]!;
  console.log(" mid props:");
  for (const p of props(mid).slice(0, 25)) console.log("   ", p[0], "->", p[2]);
  // retainers of head
  console.log(" retainers of head:");
  for (let u = 0; u < N; u++)
    for (let e = fe[u]; e < fe[u + 1]; e += E)
      if (edges[e + 2] / F === v)
        console.log(
          "   ",
          `${types[nodes[u * F + ti]]}:${String(strings[nodes[u * F + ni]]).slice(0, 60)}`,
          "via",
          etypes[edges[e]],
          etypes[edges[e]] === "element" || etypes[edges[e]] === "hidden" ? edges[e + 1] : strings[edges[e + 1]],
        );
}
