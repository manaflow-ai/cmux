#!/usr/bin/env bun
// Writes real.json for the preview page's `?real=1`: a repository checkout's docs/rfd and
// docs/reading files, each with its blob sha, newest commit date and subject, so the page shows
// the real documents with no GitHub read. The output holds that repository's text: keep it out of
// commits and public artifacts.
//   bun first-party-apps/rfd-reader/preview/real.ts REPO_CHECKOUT OUT/real.json
import { readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const [repo, out] = process.argv.slice(2)
if (!repo || !out) throw new Error("usage: real.ts REPO_CHECKOUT OUT/real.json")
const git = (...args: string[]) => new TextDecoder().decode(Bun.spawnSync(["git", "-C", repo, ...args]).stdout).trim()

const files: Record<string, { text: string; sha: string; date: string; message: string }> = {}
for (const dir of ["docs/rfd", "docs/reading"]) {
  for (const name of readdirSync(join(repo, dir)).filter((n) => n.endsWith(".md"))) {
    const path = `${dir}/${name}`
    const [date = "", message = ""] = git("log", "-1", "--format=%cI%n%s", "--", path).split("\n")
    files[path] = { text: readFileSync(join(repo, path), "utf8"), sha: git("hash-object", path), date, message }
  }
}
writeFileSync(out, JSON.stringify({ files }))
console.log(`${Object.keys(files).length} files in ${out}`)
