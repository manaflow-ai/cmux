// Prints per-frame row moves (>3px) for a dump, from the `end` phase on.
const file = process.argv[2]!;
const out = JSON.parse(await Bun.file(file).text()) as any[];
let prev: any;
let started = false;
let n = 0;
for (const s of out) {
  if (s.phase === "end") started = true;
  if (!started) { prev = s; continue; }
  n += 1;
  if (n > 70) break;
  const moves: string[] = [];
  const pm = new Map((prev?.rows ?? []).map((r: any) => [r.id, r]));
  for (const r of s.rows ?? []) {
    const p: any = pm.get(r.id);
    if (!p) { moves.push(`${r.id}:NEW`); continue; }
    const dt = r.top - p.top, dh = r.height - p.height;
    if (r.inView && (Math.abs(dt) > 3 || Math.abs(dh) > 3)) moves.push(`${r.id}:${dt.toFixed(1)}${Math.abs(dh) > 3 ? `/h${dh.toFixed(0)}` : ""}`);
  }
  for (const p of prev?.rows ?? []) if (!(s.rows ?? []).some((r: any) => r.id === p.id)) moves.push(`${p.id}:GONE`);
  console.log(`f${n} t=${(s.t - s.eventAt).toFixed(0)} ${s.phase} lag=${s.lag.toFixed(1)} st=${s.scrollTop.toFixed(0)} mounted=${s.rows?.length} ${moves.join(" ")}`);
  prev = s;
}
