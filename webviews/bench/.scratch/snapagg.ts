import fs from "node:fs";
const s = JSON.parse(fs.readFileSync(process.argv[2]!, "utf8"));
const m = s.snapshot.meta;
const nf = m.node_fields;
const F = nf.length;
const ti = nf.indexOf("type"),
  ni = nf.indexOf("name"),
  si = nf.indexOf("self_size");
const types = m.node_types[0];
const agg = new Map<string, [number, number]>();
const n = s.nodes;
for (let i = 0; i < n.length; i += F) {
  const t = types[n[i + ti]];
  let name =
    t === "string" || t === "concatenated string" || t === "sliced string"
      ? "(string)"
      : t === "code"
        ? "(code)"
        : `${t}:${String(s.strings[n[i + ni]]).slice(0, 60)}`;
  const a = agg.get(name) ?? [0, 0];
  a[0] += n[i + si];
  a[1] += 1;
  agg.set(name, a);
}
fs.writeFileSync(process.argv[3]!, JSON.stringify([...agg]));
