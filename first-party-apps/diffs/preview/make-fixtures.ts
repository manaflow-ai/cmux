// Generates preview fixtures for first-party-apps/diffs (invented data).
// Usage: bun first-party-apps/diffs/preview/make-fixtures.ts first-party-apps/diffs/preview
import { writeFileSync } from "node:fs"
const out = process.argv[2]!
const patch = `diff --git a/src/cache/lru.ts b/src/cache/lru.ts
index 3f2a1c0..9b7d4e2 100644
--- a/src/cache/lru.ts
+++ b/src/cache/lru.ts
@@ -12,14 +12,19 @@ export class LruCache<K, V> {
   private readonly entries = new Map<K, V>()
 
-  constructor(private readonly capacity: number) {}
+  constructor(private readonly capacity: number, private readonly onEvict?: (key: K, value: V) => void) {
+    if (capacity < 1) throw new RangeError("capacity must be at least 1")
+  }
 
   get(key: K): V | undefined {
     const value = this.entries.get(key)
     if (value === undefined) return undefined
     this.entries.delete(key)
     this.entries.set(key, value)
     return value
   }
 
   set(key: K, value: V): void {
     this.entries.delete(key)
     this.entries.set(key, value)
-    if (this.entries.size > this.capacity) this.entries.delete(this.entries.keys().next().value!)
+    if (this.entries.size <= this.capacity) return
+    const oldest = this.entries.keys().next().value!
+    this.onEvict?.(oldest, this.entries.get(oldest)!)
+    this.entries.delete(oldest)
   }
@@ -40,6 +45,10 @@ export class LruCache<K, V> {
   get size(): number {
     return this.entries.size
   }
+
+  clear(): void {
+    for (const [key, value] of this.entries) this.onEvict?.(key, value)
+    this.entries.clear()
+  }
 }
diff --git a/src/server/routes.ts b/src/server/routes.ts
index 81c0d11..2aa90f3 100644
--- a/src/server/routes.ts
+++ b/src/server/routes.ts
@@ -3,7 +3,7 @@ import { LruCache } from "../cache/lru"
 
-const pages = new LruCache<string, string>(100)
+const pages = new LruCache<string, string>(500, (key) => metrics.count("cache.evict", { key }))
 
 export function render(path: string): string {
   const hit = pages.get(path)
diff --git a/docs/caching.md b/docs/caching.md
new file mode 100644
index 0000000..c1d2e3f
--- /dev/null
+++ b/docs/caching.md
@@ -0,0 +1,5 @@
+# Page cache
+
+Rendered pages stay in an LRU cache of 500 entries.
+Evictions are counted as \`cache.evict\`.
+Call \`clear()\` after a deploy.
diff --git a/src/legacy/memo.ts b/src/legacy/memo.ts
deleted file mode 100644
index 77ab001..0000000
--- a/src/legacy/memo.ts
+++ /dev/null
@@ -1,3 +0,0 @@
-export function memo<T>(fn: () => T): () => T {
-  let v: T | undefined
-  return () => (v ??= fn())
-}
diff --git a/assets/logo.png b/assets/logo.png
index 1111111..2222222 100644
Binary files a/assets/logo.png and b/assets/logo.png differ
`
// Recompute every hunk header from its lines so the invented patch is consistent.
function fixHeaders(text: string): string {
  const lines = text.split("\n")
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i]!.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/)
    if (!m) continue
    let o = 0, n = 0
    for (let j = i + 1; j < lines.length && /^[ +-]/.test(lines[j]!) && !lines[j]!.startsWith("--- ") && !lines[j]!.startsWith("+++ "); j++) {
      if (lines[j]![0] !== "+") o++
      if (lines[j]![0] !== "-") n++
    }
    lines[i] = `@@ -${m[1]},${o} +${m[2]},${n} @@${m[3]}`
  }
  return lines.join("\n")
}
const fixed = fixHeaders(patch)
const files = [
  { path: "src/cache/lru.ts", status: "modified", additions: 12, deletions: 2 },
  { path: "src/server/routes.ts", status: "modified", additions: 1, deletions: 1 },
  { path: "docs/caching.md", status: "added", additions: 5, deletions: 0 },
  { path: "src/legacy/memo.ts", status: "deleted", additions: 0, deletions: 4 },
  { path: "assets/logo.png", status: "binary", additions: 0, deletions: 0, binary: true }
]
const repo = { repo: "repo_orbit", name: "orbit", branch: "cache-evictions", head: "9b7d4e2" }
const workspaces = [{ id: "workspace_orbit", session_id: "s", name: "orbit", index: 0, focused: true }]
const scopes = {
  "git.status": { scope: "git:read", class: "read" },
  "git.diff": { scope: "git:read", class: "read" },
  "diff.get": { scope: "diff:read", class: "read" },
  "diff.decide": { scope: "diff:write", class: "mutation" },
  "diff.comment.add": { scope: "diff:write", class: "mutation" },
  "feed.get": { scope: "feed:read", class: "read" },
  "feed.list": { scope: "feed:read", class: "read" },
  "feed.answer": { scope: "feed:write", class: "mutation" },
  "ui.embed.create": { scope: "embed:run", class: "mutation" },
  "app.pane.open": { scope: "workspace:read", class: "read" }
}
const gitStatus = { repo, files: [
  { ...files[0], staged: true },
  { ...files[1], staged: false },
  { ...files[2], staged: false },
  { ...files[3], staged: false },
  { ...files[4], staged: false },
  { path: "notes/todo.txt", status: "untracked", additions: 0, deletions: 0, staged: false }
] }
const worktree = { diff: "diff_worktree1", title: "orbit · cache-evictions", producer: "git", base: { kind: "git", repo: "repo_orbit", rev: "HEAD" }, head: { kind: "worktree", repo: "repo_orbit" }, files, patch: fixed, acceptVerb: "stage", rejectVerb: "discard" }
const proposal = { diff: "diff_prop7", title: "Count cache evictions and add clear()", producer: "agent", producerLabel: "agent in orbit", base: { kind: "git", repo: "repo_orbit", rev: "9b7d4e2" }, head: { kind: "snapshot", id: "snap_44" }, files: files.slice(0, 3), patch: fixed.split("diff --git a/src/legacy")[0], acceptVerb: "apply", rejectVerb: "drop", decisions: [{ path: "src/server/routes.ts", decision: "accept" }] }
const feedItem = { id: "fi_review42", title: "Review: count cache evictions", state: "open", poster: { label: "agent in orbit" }, prompt: { subject: "diff", ref: "diff_prop7", checklist: ["Evictions are counted", "clear() calls the callback"] } }
const base = { scopes, ops: { "workspace.list": workspaces, "git.status": gitStatus, "git.diff": worktree, "diff.get": proposal, "feed.get": feedItem, "feed.list": [feedItem] } }
const write = (name: string, v: unknown) => writeFileSync(`${out}/${name}.json`, JSON.stringify(v, null, 2) + "\n")
write("split", base)
write("stream", base)
write("review", base)
write("changes", base)
write("empty", { scopes, ops: { "workspace.list": workspaces, "git.status": { repo, files: [] }, "git.diff": { ...worktree, files: [], patch: "" } } })
write("missing", { ops: { "workspace.list": workspaces } })
