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
    return t === "object" || t === "native" || t === "closure" || t === "code" ? `${t}:${s.slice(0, 60)}` : `(${t})`;
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

/// What the nodes made since `early` (and alive in `late`) are, by who keeps them: the dominator tree of `late`
/// (weak, shortcut and ephemeron edges skipped, as DevTools does), each node's retained size counting only new
/// nodes. Prints the tree from the root down to nodes retaining at least `minBytes` of new memory, a single-child
/// chain on one line, so a module's top-level binding (a `system / Context` edge, named in an unminified build), a
/// DOM tree or a code cache each show as one subtree with its bytes. chat-pages-memory.bench.ts RETAINERS=1 prints
/// it for one more chat.
export function retainers(early: Snapshot, late: Snapshot, label: string, minBytes = 64 * 1024): void {
  const earlyIds = ids(early);
  const { nodes, edges, strings, nf, ef, nodeTypes, edgeTypes } = late;
  const count = nodes.length / nf;
  const firstEdge = new Int32Array(count + 1);
  for (let n = 0, e = 0; n < count; n++) {
    firstEdge[n] = e;
    e += nodes[n * nf + 4]! * ef;
  }
  firstEdge[count] = edges.length;
  const weak = edgeTypes.indexOf("weak");
  const shortcut = edgeTypes.indexOf("shortcut");
  const internal = edgeTypes.indexOf("internal");
  const skip = (e: number) => {
    const type = edges[e]!;
    if (type === weak || type === shortcut) return true;
    if (type !== internal) return false;
    const label = strings[edges[e + 1]!];
    return typeof label === "string" && label.includes("part of key");
  };
  // Depth-first postorder from the root (iterative), then Cooper-Harvey-Kennedy over reverse postorder.
  const order = new Int32Array(count).fill(-1);
  const post: number[] = [];
  const stack: number[] = [0];
  const cursor = new Int32Array(count);
  const seen = new Uint8Array(count);
  seen[0] = 1;
  for (let n = 0; n < count; n++) cursor[n] = firstEdge[n]!;
  while (stack.length) {
    const n = stack.at(-1)!;
    let pushed = false;
    while (cursor[n]! < firstEdge[n + 1]!) {
      const e = cursor[n]!;
      cursor[n] = e + ef;
      if (skip(e)) continue;
      const to = edges[e + 2]! / nf;
      if (seen[to]) continue;
      seen[to] = 1;
      stack.push(to);
      pushed = true;
      break;
    }
    if (!pushed) {
      order[n] = post.length;
      post.push(stack.pop()!);
    }
  }
  const preds: number[][] = Array.from({ length: count }, () => []);
  for (let n = 0; n < count; n++) {
    if (order[n] === -1) continue;
    for (let e = firstEdge[n]!; e < firstEdge[n + 1]!; e += ef) {
      if (skip(e)) continue;
      const to = edges[e + 2]! / nf;
      if (order[to] !== -1) preds[to]!.push(n);
    }
  }
  const idom = new Int32Array(count).fill(-1);
  idom[0] = 0;
  const intersect = (a: number, b: number) => {
    while (a !== b) {
      while (order[a]! < order[b]!) a = idom[a]!;
      while (order[b]! < order[a]!) b = idom[b]!;
    }
    return a;
  };
  for (let changed = true; changed;) {
    changed = false;
    for (let i = post.length - 2; i >= 0; i--) {
      const n = post[i]!;
      let next = -1;
      for (const p of preds[n]!) {
        if (idom[p] === -1) continue;
        next = next === -1 ? p : intersect(p, next);
      }
      if (next !== -1 && idom[n] !== next) {
        idom[n] = next;
        changed = true;
      }
    }
  }
  // Retained new bytes, children in postorder before their dominator.
  const retained = new Float64Array(count);
  for (const n of post) {
    if (!earlyIds.has(nodes[n * nf + 2]!)) retained[n]! += nodes[n * nf + 3]!;
    if (n !== 0) retained[idom[n]!]! += retained[n]!;
  }
  const children: number[][] = Array.from({ length: count }, () => []);
  for (const n of post) if (n !== 0 && retained[n]! >= minBytes) children[idom[n]!]!.push(n);
  // The edge that names a node from its dominator: the first edge from it, else from any predecessor.
  const edgeName = (from: number, to: number) => {
    for (let e = firstEdge[from]!; e < firstEdge[from + 1]!; e += ef) {
      if (edges[e + 2]! / nf !== to) continue;
      const t = edgeTypes[edges[e]!]!;
      const v = edges[e + 1]!;
      return t === "element" || t === "hidden" ? `[${v}]` : String(strings[v]).slice(0, 50);
    }
    return "~";
  };
  const name = (n: number) => {
    const t = nodeTypes[nodes[n * nf]!]!;
    const s = String(strings[nodes[n * nf + 1]!]).slice(0, 70);
    return t === "object" || t === "native" || t === "closure" || t === "code"
      ? `${t}:${s}`
      : `(${t}) ${s.slice(0, 30)}`;
  };
  // Whether pages share compiled code: one Script per URL is shared, one per page per URL is not.
  const scripts = new Map<string, number>();
  for (let n = 0; n < count; n++) {
    const s = String(strings[nodes[n * nf + 1]!]);
    if (nodeTypes[nodes[n * nf]!] === "code" && s.startsWith("system / Script / http"))
      scripts.set(s.replace(/^.*\//, ""), (scripts.get(s.replace(/^.*\//, "")) ?? 0) + 1);
  }
  console.log(
    `RETAINERS ${label}: scripts by file (count): ${[...scripts]
      .sort((a, b) => b[1] - a[1])
      .slice(0, 8)
      .map(([file, n]) => `${file} ${n}`)
      .join(", ")}`,
  );
  console.log(
    `RETAINERS ${label}: ${(retained[0]! / 1048576).toFixed(2)} MB new, by dominator (>= ${minBytes >> 10} KB)`,
  );
  const print = (n: number, depth: number) => {
    const kids = children[n]!.sort((a, b) => retained[b]! - retained[a]!);
    for (const child of kids) {
      let at = child;
      let path = `.${edgeName(n, at)} ${name(at)}`;
      while (children[at]!.length === 1 && retained[children[at]![0]!]! > retained[at]! * 0.9) {
        const next = children[at]![0]!;
        path += ` > .${edgeName(at, next)} ${name(next)}`;
        at = next;
      }
      console.log(`RETAINERS ${label} ${"  ".repeat(depth)}${(retained[child]! / 1048576).toFixed(2)} MB ${path}`);
      if (depth < 14) print(at, depth + 1);
    }
  };
  print(0, 0);
  // The long tail the tree cuts: every node a module scope (a `system / Context`) dominates, by the variable that
  // holds it (named in an unminified build), and every new node by what dominates it at the GC roots' level.
  const byBinding = new Map<string, number>();
  const byTop = new Map<string, number>();
  for (const n of post) {
    if (n === 0 || retained[n]! === 0) continue;
    const dom = idom[n]!;
    const domName = String(strings[nodes[dom * nf + 1]!]);
    if (nodeTypes[nodes[dom * nf]!] === "object" && domName.startsWith("system / Context")) {
      const key = `${edgeName(dom, n)} (${name(n).slice(0, 40)})`;
      byBinding.set(key, (byBinding.get(key) ?? 0) + retained[n]!);
    }
    if (dom === 0 || nodeTypes[nodes[dom * nf]!] === "synthetic") {
      const key = name(n)
        .replace(/@\d+/g, "")
        .replace(/http:\/\/[^ ]*\/assets\//, "")
        .replace(/-[\w-]{8}\.js/, ".js")
        .slice(0, 60);
      byTop.set(key, (byTop.get(key) ?? 0) + retained[n]!);
    }
  }
  const table = (sizes: Map<string, number>, k: number) =>
    [...sizes]
      .sort((a, b) => b[1] - a[1])
      .slice(0, k)
      .map(([key, size]) => `RETAINERS ${label}   ${(size / 1048576).toFixed(2).padStart(6)} MB  ${key}`)
      .join("\n");
  console.log(`RETAINERS ${label}: by what the roots hold\n${table(byTop, 25)}`);
  console.log(`RETAINERS ${label}: by module-scope binding\n${table(byBinding, 40)}`);
}
