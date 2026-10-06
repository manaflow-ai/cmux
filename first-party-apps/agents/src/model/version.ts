// Versions as agent CLIs print them ("2.1.281 (Claude Code)", "codex-cli
// 0.149.1", "v1.2.3-beta.2", "2026.09.30"): the first dotted number wins.
// Comparison follows semver precedence: numeric segments, then a release
// sorts after its prereleases, prerelease identifiers numerically when both
// are numbers, else by text.

export type Version = { nums: number[]; pre: string[]; text: string }

const PATTERN = /(?:^|[^0-9A-Za-z.])v?(\d+(?:\.\d+)+)(?:-([0-9A-Za-z.-]+))?/

export function parseVersion(raw: string | null | undefined): Version | null {
  if (!raw) return null
  const m = PATTERN.exec(` ${raw.trim()}`)
  if (!m) return null
  const nums = m[1]!.split(".").map((s) => Number.parseInt(s, 10))
  if (nums.some((n) => !Number.isFinite(n))) return null
  const pre = m[2] ? m[2].split(".").filter(Boolean) : []
  return { nums, pre, text: m[2] ? `${m[1]}-${m[2]}` : m[1]! }
}

function comparePre(a: string[], b: string[]): number {
  if (!a.length || !b.length) return a.length === b.length ? 0 : a.length ? -1 : 1
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i], y = b[i]
    if (x === undefined) return -1
    if (y === undefined) return 1
    const nx = /^\d+$/.test(x), ny = /^\d+$/.test(y)
    if (nx && ny) {
      const d = Number(x) - Number(y)
      if (d) return Math.sign(d)
    } else if (nx !== ny) return nx ? -1 : 1
    else if (x !== y) return x < y ? -1 : 1
  }
  return 0
}

/** -1, 0 or 1; null when either side does not parse. Missing segments count as 0. */
export function compareVersions(a: string | null | undefined, b: string | null | undefined): -1 | 0 | 1 | null {
  const x = parseVersion(a), y = parseVersion(b)
  if (!x || !y) return null
  for (let i = 0; i < Math.max(x.nums.length, y.nums.length); i++) {
    const d = (x.nums[i] ?? 0) - (y.nums[i] ?? 0)
    if (d) return d < 0 ? -1 : 1
  }
  return comparePre(x.pre, y.pre) as -1 | 0 | 1
}

export type UpdateLevel = "none" | "patch" | "minor" | "major" | "newer" | "unknown"

/** How far `latest` is ahead of `current`; "newer" when the installed build is ahead (a dev build). */
export function updateLevel(current: string | null | undefined, latest: string | null | undefined): UpdateLevel {
  const c = compareVersions(current, latest)
  if (c === null) return "unknown"
  if (c === 0) return "none"
  if (c > 0) return "newer"
  const x = parseVersion(current)!, y = parseVersion(latest)!
  if ((x.nums[0] ?? 0) !== (y.nums[0] ?? 0)) return "major"
  if ((x.nums[1] ?? 0) !== (y.nums[1] ?? 0)) return "minor"
  return "patch"
}

/** The parsed version for display ("2.1.281"), or the raw text trimmed. */
export const shortVersion = (raw: string | null | undefined): string => parseVersion(raw)?.text ?? (raw ?? "").trim()
