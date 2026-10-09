/**
 * Append-only release receipts. Each event is one JSON file created with O_EXCL
 * (never overwritten) plus one line appended to receipts.jsonl. The default
 * directory is outside every checkout (~/.local/state/cmux-release/receipts),
 * so a rehearsal in one worktree counts for an apply in another on the same
 * machine; CMUX_RELEASE_RECEIPTS_DIR overrides it (CI: the job's temp dir).
 */
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, unlinkSync, writeSync } from "node:fs"
import { homedir, hostname, userInfo } from "node:os"
import { join } from "node:path"

export interface Receipt {
  readonly action: "rehearse" | "apply" | "adopt" | "branch-created" | "branch-deleted" | "promote"
  /** One sentence: what this run did. */
  readonly what?: string
  readonly tree: string
  readonly target: string
  /** GitHub run (gh:<id>) or a fresh UUID per local invocation. */
  readonly runId?: string
  /** Applied migration file names (or the serving value) before and after the run. */
  readonly before?: ReadonlyArray<string>
  readonly after?: ReadonlyArray<string>
  /** How to undo it, newest first. */
  readonly rollback?: ReadonlyArray<string>
  readonly result: "pass" | "fail"
  readonly at: string
  readonly setHash?: string
  readonly pending?: ReadonlyArray<{ readonly name: string; readonly checksum: string }>
  readonly applied?: ReadonlyArray<string>
  readonly branch?: string
  readonly branchDeleted?: boolean
  readonly errors?: ReadonlyArray<string>
  readonly warnings?: ReadonlyArray<string>
  readonly gitSha?: string
  readonly by: string
}

export const receiptsDir = (env: Record<string, string | undefined> = process.env) =>
  env.CMUX_RELEASE_RECEIPTS_DIR || join(homedir(), ".local", "state", "cmux-release", "receipts")

export const runIdOf = (env: Record<string, string | undefined> = process.env) =>
  env.GITHUB_RUN_ID ? `gh:${env.GITHUB_RUN_ID}/${env.GITHUB_RUN_ATTEMPT ?? "1"}` : `local:${crypto.randomUUID()}`

export const actor = () => {
  let user = "unknown"
  try {
    user = userInfo().username
  } catch {}
  return process.env.GITHUB_ACTIONS ? `github-actions run ${process.env.GITHUB_RUN_ID ?? "?"}` : `${user}@${hostname()}`
}

/** Writes one receipt; returns its file path. */
export const writeReceipt = (dir: string, receipt: Receipt): string => {
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  const stamp = receipt.at.replace(/[-:.]/g, "")
  for (let i = 0; ; i++) {
    const file = join(dir, `${stamp}-${receipt.action}-${receipt.tree}-${receipt.target}${i ? `-${i}` : ""}.json`)
    try {
      const fd = openSync(file, "wx", 0o600)
      writeSync(fd, `${JSON.stringify(receipt, null, 2)}\n`)
      closeSync(fd)
      appendFileSync(join(dir, "receipts.jsonl"), `${JSON.stringify({ ...receipt, file })}\n`, { mode: 0o600 })
      return file
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e
    }
  }
}

export const readReceipts = (dir: string): Array<Receipt & { file: string }> => {
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .flatMap((f) => {
      try {
        return [{ ...(JSON.parse(readFileSync(join(dir, f), "utf8")) as Receipt), file: join(dir, f) }]
      } catch {
        return []
      }
    })
}

export const REHEARSAL_MAX_AGE_MS = 24 * 60 * 60 * 1000

/** The newest passing rehearsal of exactly this set against this target, younger than 24 h, whose branch was deleted. */
export const findRehearsal = (dir: string, tree: string, target: string, setHash: string, now = Date.now()) =>
  readReceipts(dir)
    .filter((r) => r.action === "rehearse" && r.tree === tree && r.target === target && r.result === "pass" && r.setHash === setHash && r.branchDeleted === true)
    .filter((r) => now - Date.parse(r.at) <= REHEARSAL_MAX_AGE_MS && Date.parse(r.at) <= now + 60_000)
    .at(-1)

/** Branches a rehearsal created and no receipt records as deleted (a crashed run): `db-release.ts cleanup` deletes them by exact name. */
export const strandedBranches = (dir: string) => {
  const all = readReceipts(dir)
  const deleted = new Set(all.filter((r) => r.action === "branch-deleted" && r.result === "pass").map((r) => `${r.tree}/${r.branch}`))
  return all.filter((r) => r.action === "branch-created" && !deleted.has(`${r.tree}/${r.branch}`))
}

export const LOCAL_LOCK_STALE_MS = 2 * 60 * 60 * 1000

/** A local lock file so two rehearsals or applies of one tree and target never run at once from this machine. */
export const withLocalLock = async <T>(dir: string, name: string, body: () => Promise<T>): Promise<T> => {
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  const file = join(dir, `${name}.lock`)
  let fd: number
  try {
    fd = openSync(file, "wx", 0o600)
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e
    const holder = readFileSync(file, "utf8").trim()
    const since = Date.parse(holder.split(" ")[1] ?? "")
    // A run never lasts 2 h (rehearsals delete their branch within the run); an older lock is a crashed run.
    if (!(Date.now() - since > LOCAL_LOCK_STALE_MS)) throw new Error(`another db-release run holds ${file} (${holder}); wait for it`)
    unlinkSync(file)
    fd = openSync(file, "wx", 0o600)
  }
  writeSync(fd, `${process.pid} ${new Date().toISOString()}\n`)
  closeSync(fd)
  try {
    return await body()
  } finally {
    try {
      unlinkSync(file)
    } catch {}
  }
}

/** One line for a bd comment. */
export const summaryLine = (r: Receipt, file: string) =>
  `db-release ${r.action} ${r.tree}/${r.target} ${r.result.toUpperCase()}${r.runId ? ` run=${r.runId}` : ""}${r.pending?.length ? ` files=${r.pending.map((p) => p.name.slice(0, 4)).join(",")}` : ""}${r.setHash ? ` set=${r.setHash.slice(0, 12)}` : ""}${r.branch ? ` branch=${r.branch}${r.branchDeleted ? " (deleted)" : " (NOT DELETED)"}` : ""} at=${r.at} by=${r.by} receipt=${file}`
