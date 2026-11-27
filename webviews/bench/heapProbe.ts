// l10n-allow-file: diagnostics output, not shipped UI.
// Where a growth row's bytes go (bench/growth.ts finds that an operation leaks; this finds what): heap snapshots over
// CDP, early, middle and late in a repeated operation. What was made between early and middle and is still alive late
// piled up (state rebuilt by the last operation does not count). It prints that by constructor, and by the oldest
// object holding it with that object's path from the GC roots, WeakMap entries skipped so a path is the one that keeps
// the key alive. chat-switch.bench.ts takes the snapshots on every run for its external-string row, and prints the
// rest with HEAP_PROBE=1.
/// <reference types="bun" />
import type { CDPSession } from "playwright";

export type Snapshot = {
  nodes: Int32Array | number[];
  edges: Int32Array | number[];
  strings: string[];
  nf: number;
  ef: number;
  nodeTypes: string[];
  edgeTypes: string[];
};

export async function takeSnapshot(cdp: CDPSession): Promise<Snapshot> {
  await cdp.send("HeapProfiler.enable");
  await cdp.send("HeapProfiler.collectGarbage");
  const chunks: string[] = [];
  const onChunk = (event: { chunk: string }) => chunks.push(event.chunk);
  cdp.on("HeapProfiler.addHeapSnapshotChunk", onChunk);
  await cdp.send("HeapProfiler.takeHeapSnapshot", { reportProgress: false, captureNumericValue: false } as never);
  cdp.off("HeapProfiler.addHeapSnapshotChunk", onChunk);
  const raw = JSON.parse(chunks.join(""));
  const meta = raw.snapshot.meta;
  return {
    nodes: raw.nodes,
    edges: raw.edges,
    strings: raw.strings,
    nf: meta.node_fields.length,
    ef: meta.edge_fields.length,
    nodeTypes: meta.node_types[0],
    edgeTypes: meta.edge_types[0],
  };
}

function ids(s: Snapshot): Set<number> {
  const out = new Set<number>();
  for (let i = 0; i < s.nodes.length; i += s.nf) out.add(s.nodes[i + 2]!);
  return out;
}

/// With `middle`: what was made between `early` and `middle` and is still alive at `late` (three-snapshot
/// method: per-switch state rebuilt after `middle` does not count, only what piles up).
/// Returns the bytes of the socket's and the engine's external strings (ExternalStringData) that piled up: the heap
/// usage a growth row samples does not count them, so a string kept alive by a slice of it shows only here.
export function diff(
  early: Snapshot,
  late: Snapshot,
  label: string,
  middle?: Snapshot,
  print = true,
): { externalBytes: number } {
  const earlyIds = ids(early);
  const middleIds = middle ? ids(middle) : undefined;
  const old = { has: (id: number) => earlyIds.has(id) || (middleIds !== undefined && !middleIds.has(id)) };
  const { nodes, edges, strings, nf, ef, nodeTypes, edgeTypes } = late;
  const count = nodes.length / nf;
  const name = (n: number) => {
    const t = nodeTypes[nodes[n * nf]!]!;
    const s = strings[nodes[n * nf + 1]!]!;
    return t === "object" || t === "native" || t === "closure" ? `${t}:${s.slice(0, 60)}` : `(${t})`;
  };
  const firstEdge = new Int32Array(count + 1);
  for (let n = 0, e = 0; n < count; n++) {
    firstEdge[n] = e;
    e += nodes[n * nf + 4]! * ef;
  }
  firstEdge[count] = edges.length;
  const weak = edgeTypes.indexOf("weak");
  const shortcut = edgeTypes.indexOf("shortcut");
  // Ephemeron edges (a WeakMap's table to its entries, "part of key ... -> value") do not keep a value alive on
  // their own: skip them, so a value's path is the one that keeps its key alive.
  const ephemeral = new Uint8Array(edges.length / ef);
  for (let e = 0; e < edges.length; e += ef) {
    const t = edgeTypes[edges[e]!]!;
    if (t === "internal") {
      const label = strings[edges[e + 1]!];
      if (typeof label === "string" && label.includes("part of key")) ephemeral[e / ef] = 1;
    }
  }
  // BFS from the root for distances and a parent edge.
  const dist = new Int32Array(count).fill(-1);
  const parent = new Int32Array(count).fill(-1);
  const parentEdge = new Int32Array(count).fill(-1);
  const queue = new Int32Array(count);
  let head = 0;
  let tail = 0;
  dist[0] = 0;
  queue[tail++] = 0;
  while (head < tail) {
    const n = queue[head++]!;
    for (let e = firstEdge[n]!; e < firstEdge[n + 1]!; e += ef) {
      const type = edges[e]!;
      if (type === weak || type === shortcut) continue;
      if (ephemeral[e / ef]) continue;
      const to = edges[e + 2]! / nf;
      if (dist[to] !== -1) continue;
      dist[to] = dist[n]! + 1;
      parent[to] = n;
      parentEdge[to] = e;
      queue[tail++] = to;
    }
  }
  const edgeName = (e: number) => {
    const t = edgeTypes[edges[e]!]!;
    const v = edges[e + 1]!;
    return t === "element" || t === "hidden" ? `[${v}]` : String(strings[v]).slice(0, 40);
  };
  const byCtor = new Map<string, { n: number; size: number }>();
  const byHolder = new Map<string, { n: number; size: number }>();
  const byRoot = new Map<string, { n: number; size: number }>();
  let total = 0;
  for (let n = 0; n < count; n++) {
    if (old.has(nodes[n * nf + 2]!) || dist[n] === -1) continue;
    const size = nodes[n * nf + 3]!;
    total += size;
    const c = name(n);
    const a = byCtor.get(c) ?? { n: 0, size: 0 };
    a.n++;
    a.size += size;
    byCtor.set(c, a);
    // Walk up to the first old ancestor; key = that ancestor plus the last 3 edges into the new subtree.
    const path: string[] = [];
    let at = n;
    let guard = 0;
    while (parent[at]! >= 0 && guard++ < 200) {
      const p = parent[at]!;
      path.push(edgeName(parentEdge[at]!));
      at = p;
      if (old.has(nodes[at * nf + 2]!)) break;
    }
    // Then the old holder's own path, 4 edges, to name it.
    const above: string[] = [];
    let up = at;
    for (let k = 0; k < 4 && parent[up]! >= 0; k++) {
      above.push(`${name(parent[up]!)}.${edgeName(parentEdge[up]!)}`);
      up = parent[up]!;
    }
    const key = `${above.reverse().join(" > ")} >> ${name(at)} .${path.reverse().slice(0, 3).join(".")}`;
    const root = `${above
      .join(" > ")
      .replace(/\[\d+\]/g, "[]")
      .replace(/@\d+/g, "")} >> ${name(at)}`;
    const r = byRoot.get(root) ?? { n: 0, size: 0 };
    r.n++;
    r.size += size;
    byRoot.set(root, r);
    const h = byHolder.get(key) ?? { n: 0, size: 0 };
    h.n++;
    h.size += size;
    byHolder.set(key, h);
  }
  const externalBytes = byCtor.get("native:system / ExternalStringData")?.size ?? 0;
  if (!print) return { externalBytes };
  const top = (m: Map<string, { n: number; size: number }>, k: number) =>
    [...m.entries()].sort((a, b) => b[1].size - a[1].size).slice(0, k);
  console.log(`HEAPDIFF ${label}: ${Math.round(total / 1024)} KB new and reachable`);
  for (const [k, v] of top(byCtor, 30))
    console.log(`HEAPDIFF ${label} ctor ${Math.round(v.size / 1024)}KB n=${v.n} ${k}`);
  for (const [k, v] of top(byRoot, 40))
    console.log(`HEAPDIFF ${label} root ${Math.round(v.size / 1024)}KB n=${v.n} ${k}`);
  for (const [k, v] of top(byHolder, 15))
    console.log(`HEAPDIFF ${label} holder ${Math.round(v.size / 1024)}KB n=${v.n} ${k}`);
  return { externalBytes };
}
