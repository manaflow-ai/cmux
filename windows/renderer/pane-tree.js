import { clampPaneLayoutPercent } from "./layout-utils.js";

export const paneTreeLayoutsStorageKey = "cmux.paneTreeLayouts";

const paneTreeRatioMin = 0.01;
const paneTreeRatioMax = 0.99;

function createPaneSplitId() {
  return `split_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

export function paneTreeDirection(value) {
  return value === "down" ? "down" : "right";
}

export function paneTreeRatio(value) {
  const ratio = Number(value);
  return Math.min(paneTreeRatioMax, Math.max(paneTreeRatioMin, Number.isFinite(ratio) ? ratio : 0.5));
}

export function paneTreeLeaf(panelId) {
  return { type: "pane", panelId: String(panelId || "") };
}

export function paneTreeSplit(direction, first, second, ratio = 0.5, splitId = createPaneSplitId()) {
  return {
    type: "split",
    id: /^[a-z0-9_-]+$/i.test(splitId || "") ? splitId : createPaneSplitId(),
    direction: paneTreeDirection(direction),
    ratio: paneTreeRatio(ratio),
    first,
    second
  };
}

export function clonePaneTree(node) {
  if (!node || typeof node !== "object") return null;
  if (node.type === "pane") return paneTreeLeaf(node.panelId);
  if (node.type === "split") {
    const first = clonePaneTree(node.first);
    const second = clonePaneTree(node.second);
    if (!first) return second;
    if (!second) return first;
    return paneTreeSplit(node.direction, first, second, node.ratio, node.id);
  }
  return null;
}

export function normalizePaneTree(node, allowedPanelIds, seenPanelIds = new Set()) {
  if (!node || typeof node !== "object") return null;
  if (node.type === "pane") {
    const panelId = String(node.panelId || "");
    if (!allowedPanelIds.has(panelId) || seenPanelIds.has(panelId)) return null;
    seenPanelIds.add(panelId);
    return paneTreeLeaf(panelId);
  }
  if (node.type !== "split") return null;
  const first = normalizePaneTree(node.first, allowedPanelIds, seenPanelIds);
  const second = normalizePaneTree(node.second, allowedPanelIds, seenPanelIds);
  if (!first) return second;
  if (!second) return first;
  return paneTreeSplit(node.direction, first, second, node.ratio, node.id);
}

export function paneTreeLeafIds(node, ids = []) {
  if (!node) return ids;
  if (node.type === "pane") {
    if (node.panelId) ids.push(node.panelId);
    return ids;
  }
  paneTreeLeafIds(node.first, ids);
  paneTreeLeafIds(node.second, ids);
  return ids;
}

export function paneTreeLeafCount(node) {
  return paneTreeLeafIds(node).length;
}

export function appendPaneTreeLeaf(tree, panelId, direction) {
  return appendPaneTreeLeafWithCount(tree, panelId, direction, paneTreeLeafCount(tree)).tree;
}

function appendPaneTreeLeafWithCount(tree, panelId, direction, existingCount = 0) {
  const leaf = paneTreeLeaf(panelId);
  if (!tree) return { tree: leaf, count: 1 };
  const count = Math.max(1, Math.round(Number(existingCount) || 1));
  return {
    tree: paneTreeSplit(direction, tree, leaf, count / (count + 1)),
    count: count + 1
  };
}

export function buildPaneTreeFromPanelIds(panelIds, direction) {
  let tree = null;
  let leafCount = 0;
  for (const panelId of panelIds) {
    const next = appendPaneTreeLeafWithCount(tree, panelId, direction, leafCount);
    tree = next.tree;
    leafCount = next.count;
  }
  return tree;
}

export function loadPaneTreeLayouts() {
  try {
    const parsed = JSON.parse(localStorage.getItem(paneTreeLayoutsStorageKey) || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return new Map();
    const entries = [];
    for (const [workspaceId, tree] of Object.entries(parsed)) {
      const normalized = clonePaneTree(tree);
      if (workspaceId && normalized) entries.push([workspaceId, normalized]);
    }
    return new Map(entries);
  } catch {
    return new Map();
  }
}

export function savePaneTreeLayouts(paneTrees) {
  if (!paneTrees || paneTrees.size === 0) {
    localStorage.removeItem(paneTreeLayoutsStorageKey);
    return;
  }
  const payload = {};
  for (const [workspaceId, tree] of paneTrees.entries()) {
    const normalized = clonePaneTree(tree);
    if (workspaceId && normalized) payload[workspaceId] = normalized;
  }
  if (Object.keys(payload).length === 0) localStorage.removeItem(paneTreeLayoutsStorageKey);
  else localStorage.setItem(paneTreeLayoutsStorageKey, JSON.stringify(payload));
}

export function removePanelFromPaneTree(tree, panelId) {
  if (!tree) return null;
  const remaining = new Set(paneTreeLeafIds(tree).filter((candidate) => candidate !== panelId));
  return normalizePaneTree(tree, remaining);
}

export function insertPanelAtLeaf(node, anchorPanelId, panelId, direction, placement = "after") {
  if (!node) return { node: paneTreeLeaf(panelId), inserted: true };
  if (node.type === "pane") {
    if (node.panelId !== anchorPanelId) return { node, inserted: false };
    const anchor = paneTreeLeaf(anchorPanelId);
    const inserted = paneTreeLeaf(panelId);
    return {
      node: placement === "before"
        ? paneTreeSplit(direction, inserted, anchor)
        : paneTreeSplit(direction, anchor, inserted),
      inserted: true
    };
  }
  const first = insertPanelAtLeaf(node.first, anchorPanelId, panelId, direction, placement);
  if (first.inserted) {
    return {
      node: paneTreeSplit(node.direction, first.node, node.second, node.ratio, node.id),
      inserted: true
    };
  }
  const second = insertPanelAtLeaf(node.second, anchorPanelId, panelId, direction, placement);
  if (second.inserted) {
    return {
      node: paneTreeSplit(node.direction, node.first, second.node, node.ratio, node.id),
      inserted: true
    };
  }
  return { node, inserted: false };
}

export function paneTreeContainsPanel(node, panelId) {
  if (!node) return false;
  if (node.type === "pane") return node.panelId === panelId;
  return paneTreeContainsPanel(node.first, panelId) || paneTreeContainsPanel(node.second, panelId);
}

export function swapPaneTreePanelIds(node, firstPanelId, secondPanelId) {
  const firstId = String(firstPanelId || "");
  const secondId = String(secondPanelId || "");
  if (!node || !firstId || !secondId || firstId === secondId) return clonePaneTree(node);
  if (!paneTreeContainsPanel(node, firstId) || !paneTreeContainsPanel(node, secondId)) {
    return clonePaneTree(node);
  }
  return swapPaneTreePanelIdsUnchecked(node, firstId, secondId);
}

export function replacePaneTreePanelId(node, previousPanelId, nextPanelId) {
  const previousId = String(previousPanelId || "");
  const nextId = String(nextPanelId || "");
  if (!node || !previousId || !nextId || previousId === nextId) return clonePaneTree(node);
  return replacePaneTreePanelIdUnchecked(node, previousId, nextId);
}

function replacePaneTreePanelIdUnchecked(node, previousId, nextId) {
  if (!node || typeof node !== "object") return null;
  if (node.type === "pane") {
    return paneTreeLeaf(node.panelId === previousId ? nextId : node.panelId);
  }
  if (node.type === "split") {
    return paneTreeSplit(
      node.direction,
      replacePaneTreePanelIdUnchecked(node.first, previousId, nextId),
      replacePaneTreePanelIdUnchecked(node.second, previousId, nextId),
      node.ratio,
      node.id
    );
  }
  return clonePaneTree(node);
}

function swapPaneTreePanelIdsUnchecked(node, firstId, secondId) {
  if (!node || typeof node !== "object") return null;
  if (node.type === "pane") {
    if (node.panelId === firstId) return paneTreeLeaf(secondId);
    if (node.panelId === secondId) return paneTreeLeaf(firstId);
    return paneTreeLeaf(node.panelId);
  }
  if (node.type === "split") {
    return paneTreeSplit(
      node.direction,
      swapPaneTreePanelIdsUnchecked(node.first, firstId, secondId),
      swapPaneTreePanelIdsUnchecked(node.second, firstId, secondId),
      node.ratio,
      node.id
    );
  }
  return clonePaneTree(node);
}

export function paneTreeSplitForPanel(node, panelId) {
  return paneTreeSplitSearch(node, panelId).result;
}

function paneTreeSplitSearch(node, panelId) {
  if (!node) return { contains: false, result: null };
  if (node.type === "pane") return { contains: node.panelId === panelId, result: null };
  if (node.type !== "split") return { contains: false, result: null };
  const first = paneTreeSplitSearch(node.first, panelId);
  if (first.result) return { contains: true, result: first.result };
  const second = paneTreeSplitSearch(node.second, panelId);
  if (second.result) return { contains: true, result: second.result };
  if (first.contains) return { contains: true, result: { split: node, activeInFirst: true } };
  if (second.contains) return { contains: true, result: { split: node, activeInFirst: false } };
  return { contains: false, result: null };
}

export function updatePaneTreeSplit(node, splitId, updater) {
  if (!node || node.type !== "split") return node;
  const first = updatePaneTreeSplit(node.first, splitId, updater);
  const second = updatePaneTreeSplit(node.second, splitId, updater);
  const next = paneTreeSplit(node.direction, first, second, node.ratio, node.id);
  return node.id === splitId ? updater(next) : next;
}

export function paneTreeSpanCount(node, direction) {
  if (!node || node.type === "pane") return 1;
  if (node.direction !== direction) return 1;
  return paneTreeSpanCount(node.first, direction) + paneTreeSpanCount(node.second, direction);
}

export function equalizePaneTree(node) {
  return equalizePaneTreeWithSpan(node).node;
}

function equalizePaneTreeWithSpan(node) {
  if (!node || node.type === "pane") return { node, span: 1 };
  const first = equalizePaneTreeWithSpan(node.first);
  const second = equalizePaneTreeWithSpan(node.second);
  const firstSpan = node.direction === first.node?.direction ? first.span : 1;
  const secondSpan = node.direction === second.node?.direction ? second.span : 1;
  const totalSpan = Math.max(1, firstSpan + secondSpan);
  return {
    node: paneTreeSplit(node.direction, first.node, second.node, firstSpan / totalSpan, node.id),
    span: node.direction === paneTreeDirection(node.direction) ? totalSpan : 1
  };
}

export function buildActivePanePresetTree(panels, activePanelId, direction, percent) {
  const active = panels.find((panel) => panel.id === activePanelId) || panels[0];
  if (!active) return null;
  const others = panels.filter((panel) => panel.id !== active.id).map((panel) => panel.id);
  if (others.length === 0) return paneTreeLeaf(active.id);
  const otherTree = buildPaneTreeFromPanelIds(others, direction === "down" ? "right" : "down");
  return paneTreeSplit(direction, paneTreeLeaf(active.id), otherTree, clampPaneLayoutPercent(percent) / 100);
}
