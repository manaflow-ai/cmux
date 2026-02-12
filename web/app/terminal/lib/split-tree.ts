// Discriminated union tree for split pane layout with workspaces

// --- Types ---

export type SurfaceType = "terminal" | "placeholder"

export interface GroupTab {
  id: string
  title: string
  type: SurfaceType
}

export interface PaneGroup {
  id: string
  tabs: GroupTab[]
  activeTabId: string
}

export interface LeafNode {
  type: "leaf"
  id: string // matches PaneGroup.id
}

export interface SplitNode {
  type: "split"
  id: string
  direction: "horizontal" | "vertical"
  ratio: number // 0.0–1.0, fraction for left/top child
  left: TreeNode
  right: TreeNode
}

export type TreeNode = LeafNode | SplitNode

/** A workspace is one sidebar entry — it owns a split tree of panes */
export interface Workspace {
  id: string
  title: string
  root: TreeNode
  groups: Record<string, PaneGroup>
  focusedGroupId: string
}

/** Top-level app state: a list of workspaces */
export interface AppState {
  workspaces: Record<string, Workspace>
  workspaceOrder: string[] // sidebar ordering
  activeWorkspaceId: string
}

// --- ID generation ---

let nextId = 0
export function genId(): string {
  return `s${++nextId}`
}

let nextTerminalNum = 0
export function nextTerminalTitle(): string {
  return `Terminal ${++nextTerminalNum}`
}

// --- Constructors ---

export function createLeaf(id?: string): LeafNode {
  return { type: "leaf", id: id ?? genId() }
}

export function createSplit(
  direction: "horizontal" | "vertical",
  left: TreeNode,
  right: TreeNode,
  ratio = 0.5,
): SplitNode {
  return { type: "split", id: genId(), direction, left, right, ratio }
}

export function createPaneGroup(type: SurfaceType = "terminal"): PaneGroup {
  const tabId = genId()
  const groupId = genId()
  const title = type === "terminal" ? nextTerminalTitle() : "Tab"
  return {
    id: groupId,
    tabs: [{ id: tabId, title, type }],
    activeTabId: tabId,
  }
}

export function createWorkspace(): Workspace {
  const group = createPaneGroup()
  const leaf = createLeaf(group.id)
  return {
    id: genId(),
    title: group.tabs[0].title,
    root: leaf,
    groups: { [group.id]: group },
    focusedGroupId: group.id,
  }
}

// --- Tree operations ---

/** Split a leaf into two, creating a new leaf alongside it */
export function splitLeaf(
  root: TreeNode,
  targetId: string,
  direction: "horizontal" | "vertical",
  insertAfter: boolean,
  newLeafId: string,
): TreeNode | null {
  if (root.type === "leaf") {
    if (root.id !== targetId) return null
    const newLeaf = createLeaf(newLeafId)
    const left = insertAfter ? root : newLeaf
    const right = insertAfter ? newLeaf : root
    return createSplit(direction, left, right)
  }

  const leftResult = splitLeaf(root.left, targetId, direction, insertAfter, newLeafId)
  if (leftResult) {
    return { ...root, left: leftResult }
  }

  const rightResult = splitLeaf(root.right, targetId, direction, insertAfter, newLeafId)
  if (rightResult) {
    return { ...root, right: rightResult }
  }

  return null
}

/** Remove a leaf, returning the remaining subtree (or null if it was the only leaf) */
export function removeLeaf(
  root: TreeNode,
  targetId: string,
): TreeNode | null {
  if (root.type === "leaf") {
    return root.id === targetId ? null : root
  }

  const leftResult = removeLeaf(root.left, targetId)
  const rightResult = removeLeaf(root.right, targetId)

  // Target not found in either subtree
  if (leftResult === root.left && rightResult === root.right) return root

  // Target was in left subtree
  if (leftResult !== root.left) {
    if (leftResult === null) return root.right
    return { ...root, left: leftResult }
  }

  // Target was in right subtree
  if (rightResult === null) return root.left
  return { ...root, right: rightResult }
}

/** Update the ratio on a specific split node */
export function updateRatio(
  root: TreeNode,
  splitId: string,
  ratio: number,
): TreeNode {
  if (root.type === "leaf") return root
  if (root.id === splitId) {
    return { ...root, ratio: Math.max(0.1, Math.min(0.9, ratio)) }
  }
  const left = updateRatio(root.left, splitId, ratio)
  const right = updateRatio(root.right, splitId, ratio)
  if (left === root.left && right === root.right) return root
  return { ...root, left, right }
}

/** Set all ratios to 0.5 */
export function equalize(root: TreeNode): TreeNode {
  if (root.type === "leaf") return root
  return {
    ...root,
    ratio: 0.5,
    left: equalize(root.left),
    right: equalize(root.right),
  }
}

/** Get all leaf IDs in order (left-to-right / top-to-bottom) */
export function getLeaves(root: TreeNode): string[] {
  if (root.type === "leaf") return [root.id]
  return [...getLeaves(root.left), ...getLeaves(root.right)]
}

/** Get the adjacent leaf in tree traversal order */
export function getAdjacentLeaf(
  root: TreeNode,
  currentId: string,
  direction: "next" | "prev",
): string | null {
  const leaves = getLeaves(root)
  const idx = leaves.indexOf(currentId)
  if (idx === -1) return null
  if (direction === "next") {
    return leaves[(idx + 1) % leaves.length]
  }
  return leaves[(idx - 1 + leaves.length) % leaves.length]
}

/** Spatial slot: normalized (x, y, width, height) in [0,1] space */
interface SpatialSlot {
  x: number
  y: number
  w: number
  h: number
}

/** Build a map of leaf ID → spatial slot by recursively subdividing a [0,1] rectangle.
 *  Mirrors Ghostty's spatial layout algorithm. */
export function buildSpatialMap(node: TreeNode, slot: SpatialSlot = { x: 0, y: 0, w: 1, h: 1 }): Map<string, SpatialSlot> {
  const map = new Map<string, SpatialSlot>()
  if (node.type === "leaf") {
    map.set(node.id, slot)
    return map
  }
  let leftSlot: SpatialSlot
  let rightSlot: SpatialSlot
  if (node.direction === "horizontal") {
    leftSlot = { x: slot.x, y: slot.y, w: slot.w * node.ratio, h: slot.h }
    rightSlot = { x: slot.x + slot.w * node.ratio, y: slot.y, w: slot.w * (1 - node.ratio), h: slot.h }
  } else {
    leftSlot = { x: slot.x, y: slot.y, w: slot.w, h: slot.h * node.ratio }
    rightSlot = { x: slot.x, y: slot.y + slot.h * node.ratio, w: slot.w, h: slot.h * (1 - node.ratio) }
  }
  for (const [id, s] of buildSpatialMap(node.left, leftSlot)) map.set(id, s)
  for (const [id, s] of buildSpatialMap(node.right, rightSlot)) map.set(id, s)
  return map
}

/** Get the spatial neighbor of a leaf in a given direction (left/right/up/down).
 *  Uses Ghostty's algorithm: build spatial rectangles, filter by direction, pick nearest
 *  by Euclidean distance between top-left corners. */
export function getSpatialNeighbor(
  root: TreeNode,
  currentId: string,
  dir: "left" | "right" | "up" | "down",
): string | null {
  const slots = buildSpatialMap(root)
  const source = slots.get(currentId)
  if (!source) return null

  let bestId: string | null = null
  let bestDist = Infinity

  for (const [id, slot] of slots) {
    if (id === currentId) continue
    // Filter: candidate must be strictly in the requested direction
    const inDir =
      dir === "left"  ? (slot.x + slot.w) <= source.x + 1e-9 :
      dir === "right" ? slot.x >= (source.x + source.w) - 1e-9 :
      dir === "up"    ? (slot.y + slot.h) <= source.y + 1e-9 :
      /* down */        slot.y >= (source.y + source.h) - 1e-9
    if (!inDir) continue
    // Euclidean distance between top-left corners
    const dx = slot.x - source.x
    const dy = slot.y - source.y
    const dist = Math.sqrt(dx * dx + dy * dy)
    if (dist < bestDist) {
      bestDist = dist
      bestId = id
    }
  }

  return bestId
}

/** Insert an existing tree by splitting the target leaf */
export function insertTreeAt(
  root: TreeNode,
  targetId: string,
  newTree: TreeNode,
  direction: "horizontal" | "vertical",
  insertAfter: boolean,
): TreeNode | null {
  if (root.type === "leaf") {
    if (root.id !== targetId) return null
    const left = insertAfter ? root : newTree
    const right = insertAfter ? newTree : root
    return createSplit(direction, left, right)
  }

  const leftResult = insertTreeAt(root.left, targetId, newTree, direction, insertAfter)
  if (leftResult) {
    return { ...root, left: leftResult }
  }

  const rightResult = insertTreeAt(root.right, targetId, newTree, direction, insertAfter)
  if (rightResult) {
    return { ...root, right: rightResult }
  }

  return null
}
