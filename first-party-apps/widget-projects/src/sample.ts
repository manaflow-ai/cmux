// What the Add Widget gallery's preview shows (ctx.preview): a few made-up projects on a made-up Mac.
import type { Project } from "./projects.ts"

const MINUTE = 60_000

const p = (name: string, path: string, minutesAgo: number, now: number, overlay: Project["overlay"] = {}): Project => ({
  path,
  name,
  last_used_ms: String(now - minutesAgo * MINUTE),
  overlay,
  state: "present"
})

export const SAMPLE_MACHINE = { id: "machine_sample", name: "MacBook Pro" }

export function SAMPLE_PROJECTS(now: number): Project[] {
  return [
    p("cmux", "/Users/me/code/cmux", 2, now, { pinned: true, order: 0 }),
    p("website", "/Users/me/code/website", 25, now),
    p("api", "/Users/me/code/api", 3 * 60, now),
    p("dotfiles", "/Users/me/dotfiles", 26 * 60, now),
    p("notes", "/Users/me/Documents/notes", 3 * 24 * 60, now),
    p("ios-app", "/Users/me/code/ios-app", 5 * 24 * 60, now),
    p("design-system", "/Users/me/code/design-system", 9 * 24 * 60, now),
    p("blog", "/Users/me/code/blog", 20 * 24 * 60, now)
  ]
}
