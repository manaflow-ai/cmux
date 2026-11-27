// Typed drag and drop (finder.md section 7). A drag carries typed items with
// handles, never absolute paths. The shell owns the drag session and every
// drop target outside this app; `planDrop` is the shared rule set (the app uses
// it for its own folder targets, the shell implements the same table for
// terminals and agents, and the tests pin the contract).

import { displayPath, type Location, normalizeRel } from "./handles.ts"
import type { Entry } from "./entries.ts"

export const MAX_DRAG_ITEMS = 1000

export type FileRef = { conn: string; root: string; path: string }

export type DragItem = {
  kind: "file"
  ref: FileRef
  /** Display only (the owner's display path); a target never parses it. */
  display: string
  name: string
  dir: boolean
}

export type DragPayload = { kinds: ["file"]; items: DragItem[]; operations: Array<"copy" | "move" | "reference">; truncated: boolean }

export type Rights = "read" | "read_write"

export type DropTarget =
  | { kind: "folder"; location: Location; writable: boolean }
  | { kind: "terminal"; conn: string }
  | { kind: "agent"; accepts: string[]; grant: Rights | null }

export type DropPlan =
  | { action: "copy" | "move"; to: Location; crossHost: boolean; alternatives: Array<"copy" | "move"> }
  | { action: "insert_path"; refs: FileRef[] }
  | { action: "copy_then_insert"; refs: FileRef[]; to: "terminal_drop_folder" }
  | { action: "attach"; refs: FileRef[]; rights: Rights }
  | { action: "refuse"; reason: "empty" | "read_only" | "into_itself" | "same_place" | "kind_not_accepted" | "no_file_access" }

export function buildDragPayload(location: Location, rootDisplay: string, names: readonly string[], entries: readonly Entry[], rootRights: Rights): DragPayload {
  const byName = new Map(entries.map((e) => [e.name, e]))
  const picked = names.filter((n) => byName.has(n))
  const items = picked.slice(0, MAX_DRAG_ITEMS).map((name): DragItem => {
    const e = byName.get(name)!
    const path = normalizeRel(location.path === "" ? name : `${location.path}/${name}`)
    return {
      kind: "file",
      ref: { conn: location.conn, root: location.root, path },
      display: displayPath(rootDisplay, path),
      name,
      dir: e.kind === "dir" || (e.kind === "symlink" && e.target_kind === "dir")
    }
  })
  return { kinds: ["file"], items, operations: rootRights === "read_write" ? ["copy", "move", "reference"] : ["copy", "reference"], truncated: picked.length > items.length }
}

const within = (child: string, parentPath: string) => parentPath === "" || child === parentPath || child.startsWith(`${parentPath}/`)
const parentOf = (path: string) => (path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "")

const intersect = (a: Rights, b: Rights): Rights => (a === "read_write" && b === "read_write" ? "read_write" : "read")

export function planDrop(payload: DragPayload, target: DropTarget, sourceRights: Rights): DropPlan {
  if (payload.items.length === 0) return { action: "refuse", reason: "empty" }
  const refs = payload.items.map((i) => i.ref)
  switch (target.kind) {
    case "folder": {
      if (!target.writable) return { action: "refuse", reason: "read_only" }
      const to = { ...target.location, path: normalizeRel(target.location.path) }
      const sameRoot = refs.every((r) => r.conn === to.conn && r.root === to.root)
      if (sameRoot && refs.some((r) => r.path !== "" && within(to.path, r.path))) return { action: "refuse", reason: "into_itself" }
      if (sameRoot && refs.every((r) => parentOf(r.path) === to.path)) return { action: "refuse", reason: "same_place" }
      const crossHost = refs.some((r) => r.conn !== to.conn)
      const canMove = payload.operations.includes("move")
      // Same host: move is the default (a rename on one file system). Across hosts: copy; move is offered (copy, verify, then trash the source).
      const action = !crossHost && canMove ? "move" : "copy"
      const alternatives: Array<"copy" | "move"> = canMove ? ["copy", "move"] : ["copy"]
      return { action, to, crossHost, alternatives }
    }
    case "terminal":
      // Same machine: the shell resolves each ref to a real path and types it, quoted. Another machine: copy first, then type the copy's path.
      return refs.every((r) => r.conn === target.conn) ? { action: "insert_path", refs } : { action: "copy_then_insert", refs, to: "terminal_drop_folder" }
    case "agent":
      if (!target.accepts.includes("file")) return { action: "refuse", reason: "kind_not_accepted" }
      if (!target.grant) return { action: "refuse", reason: "no_file_access" }
      return { action: "attach", refs, rights: intersect(sourceRights, target.grant) }
  }
}

/** Text the shell types into a same-host terminal once it resolved the refs (resolved paths, POSIX quoting, space separated). */
export function terminalInsertText(resolvedPaths: readonly string[], quote: (p: string) => string): string {
  return resolvedPaths.map(quote).join(" ")
}
