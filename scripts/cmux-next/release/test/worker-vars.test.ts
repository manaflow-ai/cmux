/**
 * worker-release.ts `vars`: before a deploy that sends no secrets (development), the vars the
 * deploy would set (wrangler.jsonc env.<env>.vars) must equal the serving version's plain vars.
 * Any drift (a var set by hand, a var another lane changed out of band) refuses the deploy, so
 * the job can only ship code. Fake wrangler: a script that prints STATUS_JSON / VERSION_JSON.
 */
import { describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { committedVersions, diffVars, envVars, main } from "../worker-release.ts"

const dir = mkdtempSync(join(tmpdir(), "rails-vars-"))
const calls = join(dir, "wrangler-calls.txt")
const wrangler = join(dir, "wrangler")
writeFileSync(
  wrangler,
  `#!/bin/sh
echo "$*" >> "${calls}"
case "$1" in
  deployments) [ -n "$STATUS_JSON" ] && { printf '%s' "$STATUS_JSON"; exit 0; }; echo "no deployments" >&2; exit 1 ;;
  versions) [ -n "$VERSION_JSON" ] && { printf '%s' "$VERSION_JSON"; exit 0; }; echo "no version" >&2; exit 1 ;;
esac
exit 2
`,
)
chmodSync(wrangler, 0o755)

const config = join(dir, "wrangler.jsonc")
writeFileSync(
  config,
  `{
  // top comment, with a "quote" and a // inside
  "name": "cmux-api",
  "env": {
    "development": {
      "name": "cmux-api-development",
      /* block comment */
      "vars": { "ENVIRONMENT": "development", "TEAM_VM_SNAPSHOT": "img-a", "URL": "https://x.dev/a//b", "LIMITS": { "n": 2 }, },
    },
    "staging": { "vars": { "ENVIRONMENT": "staging" } },
  },
}
`,
)

const serving = JSON.stringify({ created_on: "2026-10-09T01:00:00Z", versions: [{ version_id: "v-serving", percentage: 100 }] })
const version = (bindings: Array<Record<string, unknown>>) => JSON.stringify({ id: "v-serving", resources: { bindings } })
const same = [
  { type: "plain_text", name: "ENVIRONMENT", text: "development" },
  { type: "plain_text", name: "TEAM_VM_SNAPSHOT", text: "img-a" },
  { type: "plain_text", name: "URL", text: "https://x.dev/a//b" },
  { type: "json", name: "LIMITS", json: { n: 2 } },
  // Secrets and other bindings are never compared.
  { type: "secret_text", name: "JWT_PRIVATE_JWK" },
  { type: "durable_object_namespace", name: "TEAM_DO", class_name: "TeamDO" },
]

const run = async (argv: Array<string>, env: Record<string, string>) => {
  const logs: Array<string> = []
  const errors: Array<string> = []
  for (const [k, v] of Object.entries(env)) process.env[k] = v
  try {
    const code = await main(argv, { log: (l) => logs.push(l), error: (l) => errors.push(l) })
    return { code, logs, errors }
  } finally {
    for (const k of Object.keys(env)) delete process.env[k]
  }
}
const args = ["vars", "--worker", "cmux-api-development", "--config", config, "--env", "development", "--wrangler", wrangler]

describe("vars: the deploy may change only code", () => {
  it("reads env.<env>.vars from JSONC (comments, trailing commas, // inside strings)", () => {
    expect(envVars(readFileSync(config, "utf8"), "development")).toEqual({ ENVIRONMENT: "development", TEAM_VM_SNAPSHOT: "img-a", URL: "https://x.dev/a//b", LIMITS: { n: 2 } })
    expect(() => envVars(readFileSync(config, "utf8"), "preview")).toThrow("no env preview")
  })

  it("identical vars pass and log 'vars unchanged'", async () => {
    const r = await run(args, { STATUS_JSON: serving, VERSION_JSON: version(same) })
    expect(r.errors).toEqual([])
    expect(r.code).toBe(0)
    expect(r.logs.join("\n")).toContain("vars unchanged")
    const log = readFileSync(calls, "utf8")
    expect(log).toContain("versions view v-serving --name cmux-api-development --json")
  })

  it("a changed var refuses and names it, without printing either value", async () => {
    const drift = same.map((b) => (b.name === "TEAM_VM_SNAPSHOT" ? { ...b, text: "img-hand-set" } : b))
    const r = await run(args, { STATUS_JSON: serving, VERSION_JSON: version(drift) })
    expect(r.code).toBe(1)
    const out = [...r.logs, ...r.errors].join("\n")
    expect(out).toContain("changed: TEAM_VM_SNAPSHOT")
    expect(out).toContain("deploy refused")
    expect(out).not.toContain("img-hand-set")
    expect(out).not.toContain("img-a")
  })

  it("a var only on the serving version (the deploy would drop it) or only in the config (it would add it) refuses", async () => {
    const extra = await run(args, { STATUS_JSON: serving, VERSION_JSON: version([...same, { type: "plain_text", name: "HAND_SET", text: "1" }]) })
    expect(extra.code).toBe(1)
    expect(extra.errors.join("\n")).toContain("removed: HAND_SET")
    const missing = await run(args, { STATUS_JSON: serving, VERSION_JSON: version(same.filter((b) => b.name !== "URL")) })
    expect(missing.code).toBe(1)
    expect(missing.errors.join("\n")).toContain("added: URL")
  })

  it("a json var that differs, or a var that changes type, refuses", () => {
    expect(diffVars({ LIMITS: { n: 2 } }, [{ type: "json", name: "LIMITS", json: { n: 3 } }]).changed).toEqual(["LIMITS"])
    expect(diffVars({ N: "2" }, [{ type: "json", name: "N", json: 2 }]).changed).toEqual(["N"])
  })

  it("refuses when the serving version or its bindings cannot be read", async () => {
    const none = await run(args, { STATUS_JSON: "", VERSION_JSON: version(same) })
    expect(none.code).toBe(1)
    expect(none.errors.join()).toContain("deploy refused")
    const unread = await run(args, { STATUS_JSON: serving, VERSION_JSON: JSON.stringify({ id: "v-serving" }) })
    expect(unread.code).toBe(1)
    expect(unread.errors.join()).toContain("no bindings")
  })

  it("the committed development config parses", async () => {
    const { REPO_ROOT } = await import("../trees.ts")
    const vars = envVars(readFileSync(join(REPO_ROOT, "backend/apps/api/wrangler.jsonc"), "utf8"), "development")
    expect(vars.ENVIRONMENT).toBe("development")
    expect(existsSync(calls)).toBe(true)
  })
})

/**
 * --base-config: wrangler.jsonc at the push's BEFORE commit. The deployed vars must equal it (else
 * drift: refuse, as above); a var the push itself changes then deploys, and its change is logged.
 */
describe("vars --base-config: a var change made in the pushed commits deploys", () => {
  const before = join(dir, "wrangler.before.jsonc")
  const withSnapshot = (img: string, extra = "") => readFileSync(config, "utf8").replace('"TEAM_VM_SNAPSHOT": "img-a"', `"TEAM_VM_SNAPSHOT": "${img}"${extra}`)
  const after = join(dir, "wrangler.after.jsonc")
  const argsWith = (want: string) => ["vars", "--worker", "cmux-api-development", "--config", want, "--base-config", before, "--env", "development", "--wrangler", wrangler]

  it("a change in the push (base = deployed, config differs): passes and logs each intended change by name and plain value", async () => {
    writeFileSync(before, readFileSync(config, "utf8"))
    writeFileSync(after, withSnapshot("img-b", ', "NEW_FLAG": "1"'))
    const r = await run(argsWith(after), { STATUS_JSON: serving, VERSION_JSON: version(same) })
    expect(r.errors).toEqual([])
    expect(r.code).toBe(0)
    const out = r.logs.join("\n")
    expect(out).toContain("vars change in this push")
    expect(out).toContain("TEAM_VM_SNAPSHOT: img-a -> img-b")
    expect(out).toContain("NEW_FLAG: (unset) -> 1")
  })

  it("drift (deployed differs from the base): refuses and names the var, even when the push changes nothing", async () => {
    writeFileSync(before, readFileSync(config, "utf8"))
    const drift = same.map((b) => (b.name === "TEAM_VM_SNAPSHOT" ? { ...b, text: "img-hand-set" } : b))
    const r = await run(argsWith(config), { STATUS_JSON: serving, VERSION_JSON: version(drift) })
    expect(r.code).toBe(1)
    const out = r.errors.join("\n")
    expect(out).toContain("changed: TEAM_VM_SNAPSHOT")
    expect(out).toContain("deploy refused")
    expect(out).not.toContain("img-hand-set")
  })

  it("drift is refused also when the push changes another var", async () => {
    writeFileSync(before, readFileSync(config, "utf8"))
    writeFileSync(after, readFileSync(config, "utf8").replace('"ENVIRONMENT": "development",', '"ENVIRONMENT": "development", "NEW_FLAG": "1",'))
    const drift = same.map((b) => (b.name === "TEAM_VM_SNAPSHOT" ? { ...b, text: "img-hand-set" } : b))
    const r = await run(argsWith(after), { STATUS_JSON: serving, VERSION_JSON: version(drift) })
    expect(r.code).toBe(1)
    expect(r.errors.join("\n")).toContain("changed: TEAM_VM_SNAPSHOT")
  })

  it("no change anywhere passes as 'vars unchanged'", async () => {
    writeFileSync(before, readFileSync(config, "utf8"))
    const r = await run(argsWith(config), { STATUS_JSON: serving, VERSION_JSON: version(same) })
    expect(r.code).toBe(0)
    expect(r.logs.join("\n")).toContain("vars unchanged")
  })

  it("a deploy that was cancelled: deployed equals an older committed config (a later --base-config), not BEFORE's: passes, the repo is the source", async () => {
    // BEFORE promoted img-b, its deploy was cancelled, so the Worker still serves img-a (the commit before).
    const older = join(dir, "wrangler.older.jsonc")
    writeFileSync(older, readFileSync(config, "utf8"))
    writeFileSync(before, withSnapshot("img-b"))
    writeFileSync(after, withSnapshot("img-b"))
    const r = await run(["vars", "--worker", "cmux-api-development", "--config", after, "--base-config", before, "--base-config", older, "--env", "development", "--wrangler", wrangler], { STATUS_JSON: serving, VERSION_JSON: version(same) })
    expect(r.errors).toEqual([])
    expect(r.code).toBe(0)
    expect(r.logs.join("\n")).toContain("TEAM_VM_SNAPSHOT: img-a -> img-b")
  })

  it("a hand-set var matches none of the committed configs: still refused", async () => {
    const older = join(dir, "wrangler.older.jsonc")
    writeFileSync(older, readFileSync(config, "utf8"))
    writeFileSync(before, withSnapshot("img-b"))
    const drift = same.map((b) => (b.name === "TEAM_VM_SNAPSHOT" ? { ...b, text: "img-hand-set" } : b))
    const r = await run(["vars", "--worker", "cmux-api-development", "--config", before, "--base-config", before, "--base-config", older, "--env", "development", "--wrangler", wrangler], { STATUS_JSON: serving, VERSION_JSON: version(drift) })
    expect(r.code).toBe(1)
    expect(r.errors.join("\n")).toContain("changed: TEAM_VM_SNAPSHOT")
    expect(r.errors.join("\n")).not.toContain("img-hand-set")
  })

  it("a base config that cannot be read refuses", async () => {
    const r = await run(["vars", "--worker", "cmux-api-development", "--config", config, "--base-config", join(dir, "missing.jsonc"), "--env", "development", "--wrangler", wrangler], { STATUS_JSON: serving, VERSION_JSON: version(same) })
    expect(r.code).toBe(1)
    expect(r.errors.join()).toContain("deploy refused")
  })
})

/**
 * --base-rev / --base-path: the base configs come from git, as the versions of the config file, not as
 * the last N commits. Development deploys stayed skipped for two days (2026-11-19): the version still
 * serving was 239 commits behind the branch, outside the 100 commits the deploy job read, so every
 * later deploy would have been refused as drift although no var was set by hand.
 */
describe("vars --base-rev: the serving version is found however many commits have landed since", () => {
  const repo = mkdtempSync(join(tmpdir(), "rails-vars-git-"))
  const path = "backend/apps/api/wrangler.jsonc"
  const withSnapshot = (img: string) => readFileSync(config, "utf8").replace('"TEAM_VM_SNAPSHOT": "img-a"', `"TEAM_VM_SNAPSHOT": "${img}"`)
  const git = (...a: Array<string>) =>
    execFileSync("git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", ...a], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim()
  const commit = (text: string | undefined, message: string) => {
    if (text !== undefined) {
      writeFileSync(join(repo, path), text)
      git("add", path)
    }
    git("commit", "--quiet", "--allow-empty", "-m", message)
    return git("rev-parse", "HEAD")
  }
  git("init", "--quiet", "--initial-branch=main")
  mkdirSync(join(repo, "backend/apps/api"), { recursive: true })
  const first = commit(withSnapshot("img-0"), "config: img-0")
  const served = commit(readFileSync(config, "utf8"), "config: img-a (the version still serving)")
  const promoted = commit(withSnapshot("img-b"), "config: img-b (its deploy never ran)")
  // More commits than the old window of 100, none touching the config.
  for (let i = 0; i < 120; i++) commit(undefined, `unrelated ${i}`)
  const before = git("rev-parse", "HEAD")
  const want = join(dir, "wrangler.want.jsonc")
  writeFileSync(want, withSnapshot("img-c"))
  // The deploy job runs in the Worker's folder; the config path is from the repository root.
  const argv = (rev: string, extra: Array<string> = []) => ["vars", "--worker", "cmux-api-development", "--config", want, "--base-rev", rev, "--base-path", path, "--source-dir", join(repo, "backend/apps/api"), ...extra, "--env", "development", "--wrangler", wrangler]

  it("lists the file's versions newest first, by version and not by commit", () => {
    const versions = [...committedVersions(join(repo, "backend/apps/api"), before, path)]
    expect(versions.map((v) => v.rev)).toEqual([before, served, first])
    expect(versions.map((v) => envVars(v.text, "development").TEAM_VM_SNAPSHOT)).toEqual(["img-b", "img-a", "img-0"])
    expect(promoted).not.toBe(before)
    expect([...committedVersions(repo, before, path, 2)].map((v) => v.rev)).toEqual([before, served])
    expect(() => [...committedVersions(repo, "0000000000000000000000000000000000000001", path)]).toThrow()
    expect(() => [...committedVersions(repo, before, "backend/apps/api/missing.jsonc")]).toThrow()
  })

  it("deployed equals a version 120 commits back: passes, and the repo is the source", async () => {
    const r = await run(argv(before), { STATUS_JSON: serving, VERSION_JSON: version(same) })
    expect(r.errors).toEqual([])
    expect(r.code).toBe(0)
    expect(r.logs.join("\n")).toContain("TEAM_VM_SNAPSHOT: img-a -> img-c")
    // It stops at the version that is serving: the older img-0 version is not read.
    expect(r.logs.join("\n")).toContain("2 read")
  })

  it("a hand-set var matches no version: still refused, without its value", async () => {
    const drift = same.map((b) => (b.name === "TEAM_VM_SNAPSHOT" ? { ...b, text: "img-hand-set" } : b))
    const r = await run(argv(before), { STATUS_JSON: serving, VERSION_JSON: version(drift) })
    expect(r.code).toBe(1)
    expect(r.errors.join("\n")).toContain("changed: TEAM_VM_SNAPSHOT")
    expect(r.errors.join("\n")).not.toContain("img-hand-set")
  })

  it("the serving version is older than --base-max versions: refused, as a version outside the list is", async () => {
    const r = await run(argv(before, ["--base-max", "1"]), { STATUS_JSON: serving, VERSION_JSON: version(same) })
    expect(r.code).toBe(1)
    expect(r.errors.join("\n")).toContain("deploy refused")
  })

  it("a base that git cannot read refuses; one flag without the other is a usage error", async () => {
    const unknown = await run(argv("0000000000000000000000000000000000000001"), { STATUS_JSON: serving, VERSION_JSON: version(same) })
    expect(unknown.code).toBe(1)
    expect(unknown.errors.join()).toContain("deploy refused")
    const half = await run(["vars", "--worker", "cmux-api-development", "--config", want, "--base-rev", before, "--env", "development", "--wrangler", wrangler], { STATUS_JSON: serving, VERSION_JSON: version(same) })
    expect(half.code).toBe(2)
  })
})
