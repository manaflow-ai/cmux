// l10n-allow-file: diagnostics output, not shipped UI.
// What holds a page's JS heap (heapProbe.ts finds what piled up between snapshots; this names what one snapshot keeps):
// the snapshot's dominator tree (Cooper, Harvey and Kennedy's iterative algorithm, weak edges left out), each object's
// retained size, and the tree printed from the roots down to every holder of at least `minBytes`, each named by its
// class and the edge its dominator reaches it by. Beside it, self size by class. chat-100k-flat.bench.ts prints it for
// each launch with HEAP_RETAINERS=1.
/// <reference types="bun" />
import type { Snapshot } from "./heapProbe";

export type Retainers = { total: number; byClass: Map<string, { count: number; self: number }>; lines: string[] };

export function retainers(s: Snapshot, { minBytes = 512 * 1024, depth = 14 } = {}): Retainers {
  const { nodes, edges, strings, nf, ef, nodeTypes, edgeTypes } = s;
  const n = nodes.length / nf;
  const typeOf = (i: number) => nodeTypes[nodes[i * nf]!]!;
  const nameOf = (i: number) => strings[nodes[i * nf + 1]!]!;
  const selfOf = (i: number) => nodes[i * nf + 3]!;
  const edgeCountOf = (i: number) => nodes[i * nf + 4]!;
  const weak = edgeTypes.indexOf("weak");
  const elementLike = new Set([edgeTypes.indexOf("element"), edgeTypes.indexOf("hidden")]);
  const firstEdge = new Int32Array(n + 1);
  for (let i = 0; i < n; i++) firstEdge[i + 1] = firstEdge[i]! + edgeCountOf(i) * ef;
  const target = (e: number) => edges[e + 2]! / nf;
  const edgeName = (e: number) => {
    const t = edges[e]!;
    return elementLike.has(t) ? `[${edges[e + 1]}]` : String(strings[edges[e + 1]!] ?? edges[e + 1]);
  };
  // Postorder from the root (node 0), iterative.
  const order = new Int32Array(n).fill(-1);
  const post = new Int32Array(n);
  const stack = new Int32Array(n);
  const cursor = new Int32Array(n);
  const seen = new Uint8Array(n);
  let count = 0;
  let top = 0;
  stack[top++] = 0;
  seen[0] = 1;
  cursor[0] = firstEdge[0]!;
  while (top > 0) {
    const v = stack[top - 1]!;
    let pushed = false;
    while (cursor[v]! < firstEdge[v + 1]!) {
      const e = cursor[v]!;
      cursor[v] = e + ef;
      if (edges[e] === weak) continue;
      const w = target(e);
      if (seen[w]) continue;
      seen[w] = 1;
      cursor[w] = firstEdge[w]!;
      stack[top++] = w;
      pushed = true;
      break;
    }
    if (!pushed) {
      top--;
      order[v] = count;
      post[count++] = v;
    }
  }
  // Retainers (reverse edges) of reached nodes.
  const inCount = new Int32Array(n + 1);
  for (let v = 0; v < n; v++) {
    if (!seen[v]) continue;
    for (let e = firstEdge[v]!; e < firstEdge[v + 1]!; e += ef) if (edges[e] !== weak) inCount[target(e) + 1]! += 1;
  }
  for (let i = 0; i < n; i++) inCount[i + 1]! += inCount[i]!;
  const preds = new Int32Array(inCount[n]!);
  const fill = inCount.slice(0, n);
  for (let v = 0; v < n; v++) {
    if (!seen[v]) continue;
    for (let e = firstEdge[v]!; e < firstEdge[v + 1]!; e += ef) {
      if (edges[e] === weak) continue;
      const w = target(e);
      preds[fill[w]!++] = v;
    }
  }
  // Dominators over postorder numbers.
  const root = order[0]!;
  const idom = new Int32Array(count).fill(-1);
  idom[root] = root;
  const intersect = (a: number, b: number) => {
    while (a !== b) {
      while (a < b) a = idom[a]!;
      while (b < a) b = idom[b]!;
    }
    return a;
  };
  for (let changed = true; changed;) {
    changed = false;
    for (let p = count - 1; p >= 0; p--) {
      if (p === root) continue;
      const v = post[p]!;
      let next = -1;
      for (let k = inCount[v]!; k < inCount[v + 1]!; k++) {
        const q = order[preds[k]!]!;
        if (q < 0 || idom[q] === -1) continue;
        next = next === -1 ? q : intersect(q, next);
      }
      if (next !== -1 && idom[p] !== next) {
        idom[p] = next;
        changed = true;
      }
    }
  }
  const retained = new Float64Array(count);
  for (let p = 0; p < count; p++) retained[p] = selfOf(post[p]!);
  for (let p = 0; p < count; p++) if (p !== root) retained[idom[p]!]! += retained[p]!;
  // Children in the dominator tree, and the edge name each is reached by from its dominator when there is one.
  const kids = new Map<number, number[]>();
  for (let p = 0; p < count; p++) {
    if (p === root || retained[p]! < minBytes) continue;
    const list = kids.get(idom[p]!) ?? [];
    list.push(p);
    kids.set(idom[p]!, list);
  }
  const via = (from: number, to: number) => {
    for (let e = firstEdge[from]!; e < firstEdge[from + 1]!; e += ef) if (target(e) === to) return edgeName(e);
    return "~";
  };
  const label = (v: number) => {
    const type = typeOf(v);
    const name = nameOf(v);
    if (type === "object" || type === "native" || type === "closure") return `${name.slice(0, 60)}`;
    if (type === "string" || type === "concatenated string" || type === "sliced string") return `(${type})`;
    return `(${type}) ${name.slice(0, 40)}`;
  };
  const lines: string[] = [];
  const walk = (p: number, level: number) => {
    const list = (kids.get(p) ?? []).sort((a, b) => retained[b]! - retained[a]!);
    for (const c of list.slice(0, 12)) {
      const v = post[c]!;
      lines.push(
        `${"  ".repeat(level)}${(retained[c]! / 1048576).toFixed(2)} MB  .${via(post[p]!, v).slice(0, 40)} ${label(v)}`,
      );
      if (level < depth) walk(c, level + 1);
    }
  };
  walk(root, 0);
  const byClass = new Map<string, { count: number; self: number }>();
  let total = 0;
  for (let v = 0; v < n; v++) {
    if (!seen[v]) continue;
    const type = typeOf(v);
    const key = type === "object" || type === "native" ? nameOf(v).slice(0, 60) : `(${type})`;
    const row = byClass.get(key) ?? { count: 0, self: 0 };
    row.count += 1;
    row.self += selfOf(v);
    byClass.set(key, row);
    total += selfOf(v);
  }
  return { total, byClass, lines };
}

/// The dominator tree, and self size by class against `base` (another launch's snapshot) when there is one.
export function printRetainers(label: string, s: Snapshot, base?: Retainers): Retainers {
  const r = retainers(s);
  console.log(`heap-retainers ${label}: ${(r.total / 1048576).toFixed(1)} MB reachable; holders of >= 0.5 MB:`);
  for (const line of r.lines) console.log(`  ${line}`);
  const rows = [...r.byClass].map(([key, v]) => {
    const b = base?.byClass.get(key);
    return { key, ...v, dCount: v.count - (b?.count ?? 0), dSelf: v.self - (b?.self ?? 0) };
  });
  rows.sort((a, b) => b.dSelf - a.dSelf);
  console.log(`heap-retainers ${label}: self size by class${base ? " over the base launch" : ""} (MB, count):`);
  for (const row of rows.slice(0, 30))
    console.log(
      `  ${(row.dSelf / 1048576).toFixed(2).padStart(8)} MB ${String(row.dCount).padStart(9)}  ${row.key}` +
        (base ? `  (of ${(row.self / 1048576).toFixed(2)} MB, ${row.count})` : ""),
    );
  return r;
}
