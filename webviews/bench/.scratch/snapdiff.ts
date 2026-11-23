import fs from "node:fs";
const a = new Map<string, [number, number]>(JSON.parse(fs.readFileSync(process.argv[2]!, "utf8")));
const b = new Map<string, [number, number]>(JSON.parse(fs.readFileSync(process.argv[3]!, "utf8")));
const k = Number(process.argv[4] ?? 1);
const rows = [...b].map(([name, [sz, c]]) => [name, (sz - (a.get(name)?.[0] ?? 0)) / k, (c - (a.get(name)?.[1] ?? 0)) / k] as const).sort((x, y) => y[1] - x[1]).slice(0, 45);
let tot = 0; for (const [, [sz]] of b) tot += sz; let tota = 0; for (const [, [sz]] of a) tota += sz;
console.log(`total per page ${((tot - tota) / k / 1048576).toFixed(2)} MB`);
for (const [name, sz, c] of rows) console.log(`${(sz / 1024).toFixed(0).padStart(8)} KB ${c.toFixed(0).padStart(8)}  ${name}`);
