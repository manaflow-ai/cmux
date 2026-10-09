/**
 * worker-release.ts `vars`: before a deploy that sends no secrets (development), the vars the
 * deploy would set (wrangler.jsonc env.<env>.vars) must equal the serving version's plain vars.
 * Any drift (a var set by hand, a var another lane changed out of band) refuses the deploy, so
 * the job can only ship code. Fake wrangler: a script that prints STATUS_JSON / VERSION_JSON.
 */
import { describe, expect, it } from "bun:test"
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { diffVars, envVars, main } from "../worker-release.ts"

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
