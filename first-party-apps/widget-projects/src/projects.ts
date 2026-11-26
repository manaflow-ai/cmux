// The Projects widget's logic, with no view in it: which projects show and in what order, each
// project's lettered tile and its color, the machine's color, the short path and the "2h" age.
// Pure functions of the daemon's project.list answer, so the tests run them with no host.

export type Size = "small" | "medium" | "large"

/** The fields of a project.list row this widget reads (Cmux.ProjectSnapshot). */
export interface Project {
  path: string
  name: string
  /** Unix ms as a decimal string, as the daemon sends it. */
  last_used_ms: string
  overlay?: { rename?: string; pinned?: boolean; hidden?: boolean; order?: number }
  state?: "present" | "missing"
}

/** How many projects each size shows: a 2x2 grid, a 4x2 grid, a list of eight. */
export const COUNT: Record<Size, number> = { small: 4, medium: 8, large: 8 }

/** The project.list read: a few more than the large list shows, so hidden or missing ones never leave it short. */
export const READ = { limit: 16 } as const

/** Apple's system colors, without yellow (white letters do not read on it). A project keeps its color: it is a hash of its path. */
export const TILE_COLORS = ["#ff3b30", "#ff9500", "#34c759", "#00c7be", "#30b0c7", "#007aff", "#5856d6", "#af52de", "#ff2d55", "#a2845e"] as const

/** FNV-1a of a string, 32 bits: stable across runs and machines, so a tile's color never moves. */
export function hash(text: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h
}

export function colorOf(key: string): string {
  return TILE_COLORS[hash(key) % TILE_COLORS.length]!
}

/** The name the person sees: their rename, else the folder's name. */
export function displayName(p: Project): string {
  const rename = p.overlay?.rename?.trim()
  return rename || p.name || p.path.split("/").filter(Boolean).pop() || p.path
}

/** The tile's letter: the name's first letter or digit, upper case ("cmux-next" is C, ".dotfiles" is D). */
export function letterOf(name: string): string {
  const match = /[\p{L}\p{N}]/u.exec(name)
  return match ? match[0].toLocaleUpperCase() : "?"
}

const lastUsed = (p: Project) => Number(p.last_used_ms) || 0

/** The projects to show: present and not hidden, pinned first (in their order), then the most recently used. */
export function recent(projects: readonly Project[], count: number): Project[] {
  return projects
    .filter((p) => p.state !== "missing" && !p.overlay?.hidden)
    .slice()
    .sort((a, b) => {
      const pa = a.overlay?.pinned ? 1 : 0
      const pb = b.overlay?.pinned ? 1 : 0
      if (pa !== pb) return pb - pa
      if (pa && pb) {
        const oa = a.overlay?.order ?? Number.MAX_SAFE_INTEGER
        const ob = b.overlay?.order ?? Number.MAX_SAFE_INTEGER
        if (oa !== ob) return oa - ob
      }
      return lastUsed(b) - lastUsed(a) || displayName(a).localeCompare(displayName(b))
    })
    .slice(0, count)
}

/** The path as a person writes it: the home folder as ~ (macOS /Users/x, Linux /home/x, root). */
export function shortPath(path: string): string {
  const home = /^(\/Users\/[^/]+|\/home\/[^/]+|\/root)(?=\/|$)/.exec(path)
  return home ? `~${path.slice(home[0].length)}` : path
}

/** How long ago, as Apple's widgets write it: now, 5m, 3h, 2d, 6w. */
export function age(lastUsedMs: number, now: number): string {
  const minutes = Math.floor(Math.max(0, now - lastUsedMs) / 60_000)
  if (minutes < 1) return "now"
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h`
  const days = Math.floor(hours / 24)
  if (days < 7) return `${days}d`
  return `${Math.floor(days / 7)}w`
}

/** The machine's dot: its own color from its id, so two Macs never look alike at a glance. */
export function machineColor(id: string | undefined, name: string): string {
  return colorOf(`machine:${id || name}`)
}
