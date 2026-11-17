// The third-party notices of the web bundle, from the installed packages (every package the
// bundle may include) with each package's license text. build-web.ts writes them to
// web/THIRD_PARTY_NOTICES.txt, so they are build output, not a committed file.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"

const dir = new URL(".", import.meta.url).pathname
const nm = join(dir, "node_modules")

const packageDirs = (): string[] => {
  const out: string[] = []
  for (const name of readdirSync(nm).sort()) {
    if (name.startsWith(".")) continue
    const p = join(nm, name)
    if (name.startsWith("@")) for (const sub of readdirSync(p).sort()) out.push(join(p, sub))
    else if (statSync(p).isDirectory()) out.push(p)
  }
  return out.filter((p) => existsSync(join(p, "package.json")))
}

export function noticesText(): string {
  const appName = JSON.parse(readFileSync(join(dir, "cmux-app.v2.json"), "utf8")).id as string
  const sections = packageDirs()
    .map((p) => {
      const pkg = JSON.parse(readFileSync(join(p, "package.json"), "utf8")) as { name: string; version: string; license?: string }
      if (pkg.name.startsWith("@types/")) return null // type declarations only; not in the bundle
      if (pkg.name === "cmux-extension-sdk") return null // cmux's own SDK, under cmux's license
      const file = readdirSync(p).find((f) => /^(licen[sc]e|copying)(\.md|\.txt)?$/i.test(f))
      if (!file) throw new Error(`${pkg.name} has no license file`)
      const extra = readdirSync(p).find((f) => /^thirdpartynotices(\.txt|\.md)?$/i.test(f))
      const body = readFileSync(join(p, file), "utf8").trim()
      const notices = extra ? `\n\n--- ${pkg.name} third-party notices ---\n\n${readFileSync(join(p, extra), "utf8").trim()}` : ""
      return `${pkg.name} ${pkg.version} (${pkg.license ?? "see license"})\n\n${body}${notices}`
    })
    .filter(Boolean)
  return `Third-party software in the ${appName} web pane bundle (web/).\nWritten by build-web.ts from the installed packages.\n\n${sections.join("\n\n" + "=".repeat(78) + "\n\n")}\n`
}
