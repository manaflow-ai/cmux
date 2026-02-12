import { init } from "ghostty-web"

let p: Promise<void> | null = null

// Suppress noisy [ghostty-vt] log messages (e.g. unsupported OSC 1337)
const origLog = console.log
console.log = (...args: unknown[]) => {
  if (typeof args[0] === "string" && args[0].includes("[ghostty-vt]")) return
  origLog.apply(console, args)
}

export function ensureGhosttyInit(): Promise<void> {
  if (!p) p = init()
  return p
}
