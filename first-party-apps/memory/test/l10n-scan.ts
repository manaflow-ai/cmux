// Collects every t("key", "English") call in the app's src/ (static keys only).
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"

export function scanCalls(dir: string): Map<string, string> {
  const out = new Map<string, string>()
  const walk = (d: string) => {
    for (const name of readdirSync(d)) {
      const p = join(d, name)
      if (statSync(p).isDirectory()) walk(p)
      else if (/\.ts$/.test(name)) {
        const src = readFileSync(p, "utf8")
        for (const m of src.matchAll(/\bt\(\s*"([a-zA-Z0-9_.]+)"\s*,\s*"((?:[^"\\]|\\.)*)"/g)) out.set(m[1]!, JSON.parse(`"${m[2]}"`))
      }
    }
  }
  walk(dir)
  return out
}

/** Every t( call whose key is not a string literal (the scan, and the tables, cannot see those). */
export function dynamicCalls(dir: string): string[] {
  const out: string[] = []
  const walk = (d: string) => {
    for (const name of readdirSync(d)) {
      const p = join(d, name)
      if (statSync(p).isDirectory()) walk(p)
      else if (/\.ts$/.test(name) && name !== "l10n.ts") {
        for (const m of readFileSync(p, "utf8").matchAll(/\bt\(\s*([^"\s)][^,)]*)/g)) out.push(`${name}: ${m[1]}`)
      }
    }
  }
  walk(dir)
  return out
}
