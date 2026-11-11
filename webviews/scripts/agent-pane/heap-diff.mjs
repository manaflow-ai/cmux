// l10n-allow-file: bench output, not shipped UI.
// Heap snapshot diff for the agent-pane bench: which objects a run added and stayed (after a GC),
// grouped by constructor and by what holds them. Node ids are stable across snapshots of one page,
// so "new" means an id in the second snapshot that the first did not have.

export async function takeSnapshot(cdp) {
  const chunks = [];
  const onChunk = ({ chunk }) => chunks.push(chunk);
  cdp.on("HeapProfiler.addHeapSnapshotChunk", onChunk);
  await cdp.send("HeapProfiler.collectGarbage");
  await cdp.send("HeapProfiler.takeHeapSnapshot", { reportProgress: false, captureNumericValue: false });
  cdp.off("HeapProfiler.addHeapSnapshotChunk", onChunk);
  return parse(JSON.parse(chunks.join("")));
}

function parse(snapshot) {
  const meta = snapshot.snapshot.meta;
  const nf = meta.node_fields;
  const ef = meta.edge_fields;
  const nodeTypes = meta.node_types[0];
  const edgeTypes = meta.edge_types[0];
  const N = nf.length;
  const E = ef.length;
  const at = (fields, name) => fields.indexOf(name);
  const nType = at(nf, "type"),
    nName = at(nf, "name"),
    nId = at(nf, "id"),
    nSize = at(nf, "self_size"),
    nEdges = at(nf, "edge_count");
  const eType = at(ef, "type"),
    eName = at(ef, "name_or_index"),
    eTo = at(ef, "to_node");
  const { nodes, edges, strings } = snapshot;
  const count = nodes.length / N;
  const ids = new Float64Array(count);
  const size = new Float64Array(count);
  const label = new Array(count);
  // One retainer per node: the first strong edge that reaches it (parent node index, edge label).
  const parent = new Int32Array(count).fill(-1);
  const parentEdge = new Array(count);
  let edge = 0;
  for (let i = 0; i < count; i += 1) {
    const base = i * N;
    ids[i] = nodes[base + nId];
    size[i] = nodes[base + nSize];
    const type = nodeTypes[nodes[base + nType]];
    const name = strings[nodes[base + nName]];
    label[i] =
      type === "object" || type === "closure" || type === "native"
        ? `${type}:${name}`
        : type === "string" || type === "concatenated string" || type === "sliced string"
          ? "string"
          : `${type}:${String(name).slice(0, 40)}`;
    for (let k = 0; k < nodes[base + nEdges]; k += 1, edge += E) {
      const kind = edgeTypes[edges[edge + eType]];
      if (kind === "weak" || kind === "shortcut") continue;
      const to = edges[edge + eTo] / N;
      if (parent[to] === -1) {
        parent[to] = i;
        const nameOrIndex = edges[edge + eName];
        parentEdge[to] =
          kind === "element" || kind === "hidden"
            ? `[${kind}]`
            : kind === "internal"
              ? `<${strings[nameOrIndex]}>`
              : strings[nameOrIndex];
      }
    }
  }
  return { count, ids, size, label, parent, parentEdge };
}

function chainOf(snap, i) {
  const parts = [];
  let node = i;
  for (let hop = 0; hop < 30 && node !== -1; hop += 1) {
    const edge = snap.parentEdge[node];
    const up = snap.parent[node];
    if (up === -1) break;
    if (edge && !edge.startsWith("<")) parts.push(`${snap.label[up].slice(0, 40)}.${edge}`);
    node = up;
  }
  return parts.slice(0, 14).join(" < ");
}

// The objects in `after` that `before` did not have, by constructor and by holder ("Holder.edge").
export function diff(before, after, top = 25) {
  const known = new Set(before.ids);
  const byLabel = new Map();
  const byHolder = new Map();
  let newBytes = 0;
  let newCount = 0;
  for (let i = 0; i < after.count; i += 1) {
    if (known.has(after.ids[i])) continue;
    newBytes += after.size[i];
    newCount += 1;
    const l = after.label[i];
    const entry = byLabel.get(l) ?? { label: l, count: 0, bytes: 0 };
    entry.count += 1;
    entry.bytes += after.size[i];
    byLabel.set(l, entry);
    // Walk up past new nodes to the first old one: that is what keeps this growth alive.
    let node = i;
    let path = [];
    for (let hop = 0; hop < 12 && node !== -1 && !known.has(after.ids[node]); hop += 1) {
      path.push(`${after.label[node]}${after.parentEdge[node] ? `.${after.parentEdge[node]}` : ""}`);
      node = after.parent[node];
    }
    const holder = node === -1 ? "(root)" : `${after.label[node]} <- ${path.at(-1) ?? ""}`;
    const h = byHolder.get(holder) ?? { holder, count: 0, bytes: 0 };
    h.count += 1;
    h.bytes += after.size[i];
    byHolder.set(holder, h);
  }
  // By field: walking up from each new object, the first named property on the way (its owner's
  // constructor and the property), past array elements, Map/Set tables and closures' contexts.
  const byField = new Map();
  for (let i = 0; i < after.count; i += 1) {
    if (known.has(after.ids[i])) continue;
    let node = i;
    let field = "(none)";
    for (let hop = 0; hop < 40 && node !== -1; hop += 1) {
      const edge = after.parentEdge[node];
      const up = after.parent[node];
      if (up === -1) break;
      if (
        edge &&
        !edge.startsWith("[") &&
        !edge.startsWith("<") &&
        !/^\d+$/.test(edge) &&
        edge !== "table" &&
        edge !== "context" &&
        edge !== "elements" &&
        edge !== "properties" &&
        edge !== "value"
      ) {
        field = `${after.label[up]}.${edge}`;
        break;
      }
      node = up;
    }
    const f = byField.get(field) ?? { field, count: 0, bytes: 0, chain: chainOf(after, i) };
    f.count += 1;
    f.bytes += after.size[i];
    byField.set(field, f);
  }
  const sort = (m) =>
    [...m.values()]
      .sort((a, b) => b.bytes - a.bytes)
      .slice(0, top)
      .map((x) => ({ ...x, kb: Math.round(x.bytes / 1024) }));
  return {
    newCount,
    newKB: Math.round(newBytes / 1024),
    byLabel: sort(byLabel),
    byHolder: sort(byHolder),
    byField: sort(byField),
  };
}
