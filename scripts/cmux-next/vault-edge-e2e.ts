#!/usr/bin/env bun
/**
 * Vault edge grants, end to end on a real Cloud VM (cmux-vault docs/integrations/cmux-cloud.md, Step 6).
 *
 *   bun scripts/cmux-next/vault-edge-e2e.ts --backend dev --out DIR
 *   bun scripts/cmux-next/vault-edge-e2e.ts --backend staging --out DIR   (once staging sets VAULT_EDGE_GRANTS_ENABLED)
 *
 * An environment secret with a host is delivered by the network (a Freestyle edge rule the vault makes), never as a
 * value on the VM. This run proves it on one machine of the agent test account (CMUX_DOGFOOD_STACK_EMAIL and
 * _PASSWORD from the environment, the dev Stack project):
 *
 *   0. sign in, a throwaway cli install and its cmux access token (as machine-vault-e2e.ts);
 *   1. a fresh random value V (64 lowercase hex characters, made here, masked at once) becomes the secret
 *      VAULT_EDGE_E2E of a new personal environment, sent to PINNED_HOST only, in the header HEADER as `{value}`;
 *      a second environment with no secret is made for step 5;
 *   2. a workspace machine is ensured with the first environment (POST /v1/workspaces/{ws}/machine), and ensured
 *      again once running, so the boot's reconcile (cloudEnvironmentBootVariables -> vaultEdgeGrants) has run;
 *   3. (a) not on the VM: the VM is given only V's first NEEDLE_CHARS characters (never V) and greps every file
 *      under / (but /proc, /sys, /dev), every /proc/PID/environ and cmdline, as root when sudo asks no password;
 *      no hit may be found, and the scan must finish. The acpmux state dirs it found are listed in the evidence;
 *   4. (b) a request from the VM to PINNED_HOST's header echo carries V: the VM hashes each header value it got
 *      back and prints names and SHA-256 hashes only; one must be sha256(V);
 *      (c) a request to OTHER_HOST's header echo carries no header whose hash is sha256(V);
 *   5. (d) the machine is ensured with the second environment (no secret): the reconcile revokes the machine's rule
 *      at the vault (edgeRevoke), and PINNED_HOST then no longer gets V (re-asked for up to REVOKE_WAIT_MS);
 *   6. cleanup, in `finally`: the machine, both environments, the install and the Stack session.
 *
 * Neither echo host is ours: they are the public echo APIs machine-vault-e2e.ts already uses. V is a nonce made for
 * this run and dead after it (its environment is deleted), so its reaching postman-echo.com is the proof, not a leak.
 * Nothing printed or written holds V, the passwords or a token: every held value is masked (::add-mask::) and every
 * output line is redacted with them; the evidence file is checked for each before it is written.
 */
import { createHash, randomBytes } from "node:crypto"
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { parseArgs } from "node:util"

export const SECRET_NAME = "VAULT_EDGE_E2E"
export const HEADER = "x-vault-edge-e2e"
export const PINNED_HOST = "postman-echo.com"
export const OTHER_HOST = "httpbin.org"
export const PINNED_ECHO = `https://${PINNED_HOST}/headers`
export const OTHER_ECHO = `https://${OTHER_HOST}/headers`
/** The part of V the VM greps for: 64 of its 256 bits. Any copy of V holds it; it is not V. */
export const NEEDLE_CHARS = 16
export const GRANT_WAIT_MS = 120_000
export const REVOKE_WAIT_MS = 120_000
export const SCAN_WAIT_MS = 20 * 60_000
const USER_AGENT = "cmux-vault-edge-e2e/1"
const STACK_API = "https://api.stack-auth.com/api/v1"
// The development Stack project the dev and staging APIs trust, and its public client key (as machine-join-e2e.ts).
const DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
const DEV_STACK_CLIENT_KEY = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
/** Where the VM keeps this run's files: the needle, the scan script and its answer. */
export const GUEST_DIR = "/tmp/vault-edge-e2e"

export const BACKENDS = {
  dev: { api: "https://cmux-api-development.debussy.workers.dev", platform: "https://cmux-platform-development.debussy.workers.dev" },
  staging: { api: "https://cloud-api-staging.cmux.dev", platform: "https://cmux-platform-staging.debussy.workers.dev" },
} as const
export type BackendName = keyof typeof BACKENDS

export const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex")
export const escapeData = (s: string) => s.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A")
export const redact = (text: string, secrets: readonly string[]) =>
  secrets.reduce((t, s) => (s.length >= 8 ? t.split(s).join("[secret]") : t), text)

/**
 * The scan, as a shell program the VM runs detached (it outlives one exec's 5 min). The needle arrives on stdin into
 * GUEST_DIR/needle (0600), so it is in no argv or env; the scan skips GUEST_DIR (the needle's own file).
 * Its answer, GUEST_DIR/scan.json, has counts and paths only.
 */
export function scanStartCommand(): string {
  const d = GUEST_DIR
  const scan = [
    "set -u",
    `d=${d}`,
    'n="$d/needle"',
    // Files: every regular file outside the kernel's views, skipping this run's own dir.
    `find / \\( -path /proc -o -path /sys -o -path /dev -o -path "$d" \\) -prune -o -type f -print0 2>/dev/null | xargs -0 -r grep -lsF -f "$n" -- 2>/dev/null > "$d/files.hits"`,
    'echo "$?" > "$d/files.rc"',
    // Every process's environment and command line (the scan's own read needs the needle file, not its value).
    ': > "$d/proc.hits"',
    'for p in /proc/[0-9]*; do for f in environ cmdline; do grep -qsF -f "$n" "$p/$f" && echo "$p/$f" >> "$d/proc.hits"; done; done',
    'ls -d /proc/[0-9]* 2>/dev/null | wc -l > "$d/proc.count"',
    // acpmux's state, named in the evidence so its scan is visible (the file walk above covered it).
    `find / \\( -path /proc -o -path /sys -o -path /dev \\) -prune -o -type d -iname '*acpmux*' -print 2>/dev/null | head -20 > "$d/acpmux.dirs"`,
    'id -u > "$d/uid"',
    'touch "$d/done"',
  ].join("\n")
  return [
    "set -eu",
    `d=${d}`,
    'rm -rf "$d"; mkdir -p "$d"; chmod 700 "$d"',
    'umask 077; cat > "$d/needle"',
    `cat > "$d/scan.sh" <<'VAULT_EDGE_SCAN'\n${scan}\nVAULT_EDGE_SCAN`,
    // As root when sudo asks no password (other users' environ files), else the work user.
    'if sudo -n true 2>/dev/null; then sudo -n chown -R root "$d"; run="sudo -n"; else run=""; fi',
    'setsid nohup $run sh "$d/scan.sh" </dev/null >/dev/null 2>&1 &',
    'echo started',
  ].join("\n")
}

/** Reads the scan's answer once it is done: one JSON line, or `pending`. */
export function scanReadCommand(): string {
  const d = GUEST_DIR
  return [
    `d=${d}`,
    'if sudo -n true 2>/dev/null; then s="sudo -n"; else s=""; fi',
    'if ! $s test -e "$d/done"; then echo pending; exit 0; fi',
    `$s python3 -I -c 'import json,sys,os
d=sys.argv[1]
r=lambda f:open(os.path.join(d,f)).read()
lines=lambda f:[l for l in r(f).splitlines() if l]
print(json.dumps({"uid":int(r("uid").strip()),"files_rc":int(r("files.rc").strip()),"file_hits":lines("files.hits")[:50],"proc_hits":lines("proc.hits")[:50],"procs":int(r("proc.count").strip()),"acpmux_dirs":lines("acpmux.dirs")}))' "$d"`,
    '$s rm -rf "$d"',
  ].join("\n")
}

/**
 * One request from the VM to an echo of its own headers: the answer's status and, for each header the echo saw,
 * its lowercase name and the SHA-256 of its value. No value is printed.
 */
export function echoCommand(url: string): string {
  const py = [
    "import hashlib,json,sys,urllib.request",
    `req=urllib.request.Request(sys.argv[1],headers={"user-agent":"${USER_AGENT}"})`,
    "try:",
    "  r=urllib.request.urlopen(req,timeout=20); s=r.status; b=json.loads(r.read())",
    "except Exception as e:",
    "  print(json.dumps({\"status\":getattr(e,\"code\",0),\"error\":type(e).__name__,\"headers\":{}})); sys.exit(0)",
    "h=b.get(\"headers\") or {}",
    "print(json.dumps({\"status\":s,\"headers\":{k.lower():hashlib.sha256(str(v).encode()).hexdigest() for k,v in h.items()}}))",
  ].join("\n")
  return `python3 -I -c '${py}' '${url}'`
}

export interface EchoAnswer { status: number; error?: string; headers: Record<string, string> }
/** The header names whose value hashes to `want`. */
export const carriers = (a: EchoAnswer, want: string) => Object.entries(a.headers).filter(([, h]) => h === want).map(([k]) => k)

export interface ScanAnswer { uid: number; files_rc: number; file_hits: string[]; proc_hits: string[]; procs: number; acpmux_dirs: string[] }

export type Verdict = "pass" | "fail" | "not_run"
export interface Evidence {
  run: { id: string; backend: BackendName; platform: string; started_at: string }
  value_sha256_prefix: string
  environment: string | null
  machine: string | null
  steps: { step: string; ms: number; ok: boolean; note: string }[]
  assertions: {
    a_not_on_vm: { verdict: Verdict; scan?: ScanAnswer | { error: string } }
    b_pinned_carries: { verdict: Verdict; status?: number; carriers?: string[]; tries?: number }
    c_other_does_not: { verdict: Verdict; status?: number; carriers?: string[] }
    d_after_revoke: { verdict: Verdict; status?: number; carriers?: string[]; tries?: number; how?: string }
  }
  cleanup: { machine: boolean | null; environments: number; install: boolean | null; signedOut: boolean | null }
}

/** (a): a scan that finished (its grep walked the files: rc 0 found, 1 none) with no hit anywhere. */
export const scanPasses = (s: ScanAnswer) => (s.files_rc === 0 || s.files_rc === 1 || s.files_rc === 123) && s.file_hits.length === 0 && s.proc_hits.length === 0 && s.procs > 0

interface Options { backend: BackendName; out: string; runId: string }
export function parseCli(argv: string[]): Options {
  const { values } = parseArgs({ args: argv, options: { backend: { type: "string", default: "dev" }, out: { type: "string" }, "run-id": { type: "string" } } })
  const backend = values.backend as string
  if (!(backend in BACKENDS)) throw new Error(`--backend: one of ${Object.keys(BACKENDS).join(", ")}`)
  if (!values.out) throw new Error("--out DIR is required")
  const runId = values["run-id"] ?? `${process.env.GITHUB_RUN_ID ?? "local"}-${process.env.GITHUB_RUN_ATTEMPT ?? Date.now().toString(36)}`
  if (!/^[a-z0-9-]{1,40}$/.test(runId)) throw new Error("--run-id: lowercase letters, digits and -")
  return { backend: backend as BackendName, out: values.out, runId }
}

class Failed extends Error {}

export async function main(opts: Options): Promise<number> {
  const backend = BACKENDS[opts.backend]
  const secrets: string[] = []
  const hold = (v: string) => {
    if (!v || secrets.includes(v)) return
    process.stdout.write(`::add-mask::${escapeData(v)}\n`)
    secrets.push(v)
  }
  const say = (line: string) => process.stdout.write(`${redact(line, secrets)}\n`)
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL ?? ""
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD ?? ""
  hold(email)
  hold(password)
  if (!email || !password) throw new Error("CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD must be set")
  const value = randomBytes(32).toString("hex")
  hold(value)
  const want = sha256(value)
  const evidence: Evidence = {
    run: { id: opts.runId, backend: opts.backend, platform: backend.platform, started_at: new Date().toISOString() },
    value_sha256_prefix: want.slice(0, 12),
    environment: null,
    machine: null,
    steps: [],
    assertions: { a_not_on_vm: { verdict: "not_run" }, b_pinned_carries: { verdict: "not_run" }, c_other_does_not: { verdict: "not_run" }, d_after_revoke: { verdict: "not_run" } },
    cleanup: { machine: null, environments: 0, install: null, signedOut: null },
  }
  const step = async <T>(name: string, fn: () => Promise<T>): Promise<T> => {
    const t = Date.now()
    try {
      const v = await fn()
      evidence.steps.push({ step: name, ms: Date.now() - t, ok: true, note: "" })
      say(`PASS ${name} (${Date.now() - t} ms)`)
      return v
    } catch (e) {
      const note = redact(String((e as Error)?.message ?? e), secrets).slice(0, 300)
      evidence.steps.push({ step: name, ms: Date.now() - t, ok: false, note })
      say(`FAIL ${name}: ${note}`)
      throw e
    }
  }
  const http = async (method: string, url: string, body?: unknown, headers: Record<string, string> = {}, timeoutMs = 60_000) => {
    const res = await fetch(url, {
      method,
      redirect: "error",
      signal: AbortSignal.timeout(timeoutMs),
      headers: { "user-agent": USER_AGENT, accept: "application/json", ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    const json = (await res.json().catch(() => ({}))) as any
    return { status: res.status, json }
  }
  const codeOf = (r: { status: number; json: any }) => {
    const c = [r.json?.code, r.json?.error?.code, r.json?.value?.error?.code].find((x) => typeof x === "string" && /^[A-Za-z0-9._-]{1,80}$/.test(x))
    return `HTTP ${r.status}${c ? ` ${c}` : ""}`
  }
  const stackHeaders = { "x-stack-project-id": DEV_STACK_PROJECT, "x-stack-publishable-client-key": DEV_STACK_CLIENT_KEY, "x-stack-access-type": "client" }

  let stack: { access: string; refresh: string } | undefined
  let user = ""
  let install = ""
  let keys: CryptoKeyPair | undefined
  let access: { token: string; expiresAt: number } | undefined
  let machine = ""
  let team = ""
  const environments: string[] = []

  const op = async (name: string, params: unknown) => {
    const r = await http("POST", `${backend.api}/v1/ops`, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" }, { authorization: `Bearer ${stack!.access}` })
    if (r.status !== 200 || r.json?.ok !== true) throw new Failed(`${name}: ${codeOf(r)}`)
    return r.json.value
  }
  const token = async () => {
    if (access && access.expiresAt - Date.now() > 60_000) return access.token
    const ch = await http("POST", `${backend.api}/v1/auth/challenge`, { user, install })
    if (ch.status !== 200 || typeof ch.json?.nonce !== "string") throw new Failed(`auth challenge: ${codeOf(ch)}`)
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys!.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const tok = await http("POST", `${backend.api}/v1/auth/token`, { user, install, nonce: ch.json.nonce, signature: Buffer.from(sig).toString("base64url") })
    if (typeof tok.json?.access_token === "string") hold(tok.json.access_token)
    if (tok.status !== 200 || typeof tok.json?.access_token !== "string") throw new Failed(`auth token: ${codeOf(tok)}`)
    const expiresAt = Number(tok.json.expires_at)
    access = { token: tok.json.access_token, expiresAt: expiresAt > 1e12 ? expiresAt : expiresAt > 0 ? expiresAt * 1000 : Date.now() + 300_000 }
    return access.token
  }
  const platform = async (method: string, path: string, body?: unknown, timeoutMs = 60_000) =>
    http(method, `${backend.platform}${path}`, body, { authorization: `Bearer ${await token()}`, ...(team ? { "x-cmux-team": team } : {}) }, timeoutMs)
  const exec = async (command: string, stdin?: string, timeoutMs = 60_000) => {
    const r = await platform("POST", `/v1/cloud/machines/${machine}/exec`, { command, timeoutMs, ...(stdin === undefined ? {} : { stdinBase64: Buffer.from(stdin).toString("base64") }) }, timeoutMs + 15_000)
    const v = r.json?.value ?? r.json
    if (r.status < 200 || r.status >= 300 || v?.ok === false) throw new Failed(`exec: ${codeOf(r)}`)
    return { code: Number(v.exitCode ?? v.exit_code ?? 1), stdout: String(v.stdout ?? ""), stderr: String(v.stderr ?? "") }
  }
  const lastJson = (text: string) => {
    for (const line of text.trim().split("\n").reverse()) {
      try {
        return JSON.parse(line)
      } catch {}
    }
    return null
  }
  const echo = async (url: string): Promise<EchoAnswer> => {
    const r = await exec(echoCommand(url), undefined, 45_000)
    const a = lastJson(r.stdout)
    if (!a || typeof a.headers !== "object") throw new Failed(`echo ${new URL(url).host}: no answer (exit ${r.code})`)
    return a as EchoAnswer
  }
  const workspace = `vault-edge-e2e-${opts.runId}`
  const ensure = async (environment: string) => {
    const r = await platform("POST", `/v1/workspaces/${workspace}/machine`, { clientKey: workspace, environment }, 180_000)
    if (r.status !== 200 || typeof r.json?.machine?.id !== "string") throw new Failed(`workspace ensure: ${codeOf(r)}`)
    return r.json
  }
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

  let failed = false
  try {
    await step("sign in", async () => {
      const r = await http("POST", `${STACK_API}/auth/password/sign-in`, { email, password }, stackHeaders)
      for (const k of ["access_token", "refresh_token"]) if (typeof r.json?.[k] === "string") hold(r.json[k])
      if (r.status !== 200 || typeof r.json?.access_token !== "string") throw new Failed(`stack sign-in: ${codeOf(r)}`)
      stack = { access: r.json.access_token, refresh: String(r.json.refresh_token ?? "") }
      user = String((await op("user.ensure", {}))?.id ?? "")
      keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair
      const jwk = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey
      install = String((await op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: `vault-edge-e2e ${opts.runId}`.slice(0, 80), device_name: "vault-edge-e2e runner", platform: "linux" }))?.id ?? "")
      await token()
    })

    const env = await step("environment with the secret", async () => {
      const made = await platform("POST", "/v1/cloud-environments", {
        name: `vault-edge-e2e ${opts.runId}`.slice(0, 64),
        scope: "personal",
        secrets: [{ name: SECRET_NAME, value, hosts: [PINNED_HOST], header: { name: HEADER, format: "{value}" } }],
      })
      if (typeof made.json?.id === "string") environments.push(made.json.id)
      if (made.status !== 200 && made.status !== 201) throw new Failed(`create environment: ${codeOf(made)}`)
      const listed = (made.json.secrets ?? []).find((s: any) => s?.name === SECRET_NAME)
      if (!listed || listed.hosts?.[0] !== PINNED_HOST) throw new Failed("the environment does not list the secret with its host")
      if (JSON.stringify(made.json).includes(value)) throw new Failed("the platform answered the secret's value")
      evidence.environment = made.json.id
      const bare = await platform("POST", "/v1/cloud-environments", { name: `vault-edge-e2e ${opts.runId} none`.slice(0, 64), scope: "personal" })
      if (typeof bare.json?.id === "string") environments.push(bare.json.id)
      if (bare.status !== 200 && bare.status !== 201) throw new Failed(`create the second environment: ${codeOf(bare)}`)
      return { withSecret: made.json.id as string, without: bare.json.id as string }
    })

    await step("machine with the environment", async () => {
      const first = await ensure(env.withSecret)
      machine = first.machine.id
      team = String(first.team ?? "")
      evidence.machine = machine
      say(`machine ${machine} (${first.machine.state ?? "?"}, created ${first.created})`)
      const until = Date.now() + 240_000
      for (;;) {
        const ok = await exec("true", undefined, 15_000).then((r) => r.code === 0, () => false)
        if (ok) break
        if (Date.now() > until) throw new Failed("the machine's exec never answered within 240 s")
        await sleep(5_000)
      }
      // Once it runs: the ensure that grants (a boot before running may not have reached the guest yet).
      await ensure(env.withSecret)
    })

    // (a) before any echo, so the only copy an echo answer could leave is not there yet.
    await step("(a) the value is not on the VM", async () => {
      const started = await exec(scanStartCommand(), value.slice(0, NEEDLE_CHARS) + "\n", 60_000)
      if (started.code !== 0 || !started.stdout.includes("started")) throw new Failed(`scan start: exit ${started.code}`)
      const until = Date.now() + SCAN_WAIT_MS
      let scan: ScanAnswer | null = null
      while (!scan) {
        await sleep(15_000)
        const r = await exec(scanReadCommand(), undefined, 60_000).catch(() => null)
        if (r && !r.stdout.includes("pending")) scan = lastJson(r.stdout)
        if (!scan && Date.now() > until) throw new Failed(`the scan did not finish within ${SCAN_WAIT_MS / 60_000} min`)
      }
      evidence.assertions.a_not_on_vm = { verdict: scanPasses(scan) ? "pass" : "fail", scan }
      say(`scan: uid ${scan.uid}, ${scan.file_hits.length} file hits, ${scan.proc_hits.length} process hits over ${scan.procs} processes, acpmux dirs ${scan.acpmux_dirs.length}`)
      if (!scanPasses(scan)) throw new Failed("the value (its first characters) is on the VM")
    })

    await step("(b) the pinned host gets the secret", async () => {
      const until = Date.now() + GRANT_WAIT_MS
      for (let tries = 1; ; tries++) {
        const a = await echo(PINNED_ECHO)
        const c = carriers(a, want)
        evidence.assertions.b_pinned_carries = { verdict: c.length ? "pass" : "fail", status: a.status, carriers: c, tries }
        if (c.length) return
        if (Date.now() > until) throw new Failed(`${PINNED_HOST} (HTTP ${a.status}) got no header with the value's hash after ${tries} tries`)
        await sleep(10_000)
      }
    })

    await step("(c) another host does not", async () => {
      const a = await echo(OTHER_ECHO)
      const c = carriers(a, want)
      const ok = a.status === 200 && c.length === 0
      evidence.assertions.c_other_does_not = { verdict: ok ? "pass" : "fail", status: a.status, carriers: c }
      if (!ok) throw new Failed(a.status !== 200 ? `${OTHER_HOST} answered HTTP ${a.status}: not judged` : `${OTHER_HOST} got the value in ${c.join(", ")}`)
    })

    await step("(d) after edgeRevoke the pinned host does not", async () => {
      // The machine's environment changes to one with no secret: the boot reconcile revokes its rule (edgeRevoke).
      await ensure(env.without)
      const until = Date.now() + REVOKE_WAIT_MS
      for (let tries = 1; ; tries++) {
        const a = await echo(PINNED_ECHO)
        const c = carriers(a, want)
        const ok = a.status === 200 && c.length === 0
        evidence.assertions.d_after_revoke = { verdict: ok ? "pass" : "fail", status: a.status, carriers: c, tries, how: "ensure with an environment without the secret" }
        if (ok) return
        if (Date.now() > until) throw new Failed(`${PINNED_HOST} still got the value ${REVOKE_WAIT_MS / 1000} s after the revoke (${tries} tries)`)
        await sleep(10_000)
      }
    })
  } catch (e) {
    failed = true
    if (!(e instanceof Failed)) say(`error: ${redact(String((e as Error)?.message ?? e), secrets).slice(0, 300)}`)
  } finally {
    if (machine) {
      const del = await platform("DELETE", `/v1/machines/${machine}`).catch(() => null)
      let ok = !!del && ((del.status >= 200 && del.status < 300) || del.status === 404)
      if (!ok) {
        const r = await http("POST", `${backend.api}/v1/ops`, { op: "cloud.machine.delete", params: { machine }, idempotency_key: `vault-edge-e2e-${opts.runId}-delete` }, { authorization: `Bearer ${await token().catch(() => "")}` }).catch(() => null)
        ok = !!r && r.status === 200 && r.json?.ok === true
      }
      evidence.cleanup.machine = ok
      say(ok ? `cleanup: machine ${machine} deleted` : `cleanup: could not delete machine ${machine} (${del ? codeOf(del) : "no answer"})`)
      if (!ok) failed = true
    }
    for (const id of environments) {
      const r = await platform("DELETE", `/v1/cloud-environments/${id}`).catch(() => null)
      if (r && ((r.status >= 200 && r.status < 300) || r.status === 404)) evidence.cleanup.environments++
      else {
        failed = true
        say(`cleanup: could not delete environment ${id} (${r ? codeOf(r) : "no answer"})`)
      }
    }
    if (install && stack) {
      evidence.cleanup.install = await op("install.revoke", { install }).then(() => true, () => false)
      if (!evidence.cleanup.install) failed = true
    }
    if (stack) {
      const out = await http("DELETE", `${STACK_API}/auth/sessions/current`, undefined, { ...stackHeaders, "x-stack-access-token": stack.access, "x-stack-refresh-token": stack.refresh }).catch(() => null)
      evidence.cleanup.signedOut = !!out && out.status >= 200 && out.status < 300
    }
    const text = JSON.stringify(evidence, null, 2)
    if (secrets.some((s) => s.length >= 8 && text.includes(s)) || text.includes(value.slice(0, NEEDLE_CHARS))) {
      say("the evidence holds a secret: not written")
      failed = true
    } else {
      mkdirSync(opts.out, { recursive: true })
      writeFileSync(join(opts.out, "evidence.json"), `${text}\n`)
      writeFileSync(join(opts.out, "summary.md"), summary(evidence))
    }
  }
  const all = Object.values(evidence.assertions).every((a) => a.verdict === "pass")
  return failed || !all ? 1 : 0
}

export function summary(e: Evidence): string {
  const row = (k: string, label: string, a: { verdict: Verdict }, detail: string) => `| ${k} | ${label} | ${a.verdict} | ${detail} |`
  const A = e.assertions
  const scan = A.a_not_on_vm.scan && "file_hits" in A.a_not_on_vm.scan ? A.a_not_on_vm.scan : null
  return [
    `## Vault edge grants E2E (${e.run.backend}, run ${e.run.id})`,
    "",
    `Platform ${e.run.platform}; machine ${e.machine ?? "none"}; environment ${e.environment ?? "none"}; value sha256 ${e.value_sha256_prefix}...`,
    "",
    "| # | Assertion | Verdict | Detail |",
    "|---|---|---|---|",
    row("a", "value not in the VM's files, /proc/*/environ, cmdline or acpmux state", A.a_not_on_vm, scan ? `uid ${scan.uid}; ${scan.file_hits.length} file hits; ${scan.proc_hits.length} process hits of ${scan.procs}; acpmux dirs: ${scan.acpmux_dirs.join(" ") || "none"}` : ""),
    row("b", `request to ${PINNED_HOST} carries it (hash)`, A.b_pinned_carries, A.b_pinned_carries.status ? `HTTP ${A.b_pinned_carries.status}; in ${A.b_pinned_carries.carriers?.join(", ") || "no header"}; tries ${A.b_pinned_carries.tries}` : ""),
    row("c", `request to ${OTHER_HOST} does not`, A.c_other_does_not, A.c_other_does_not.status ? `HTTP ${A.c_other_does_not.status}; in ${A.c_other_does_not.carriers?.join(", ") || "no header"}` : ""),
    row("d", `after edgeRevoke ${PINNED_HOST} does not`, A.d_after_revoke, A.d_after_revoke.status ? `HTTP ${A.d_after_revoke.status}; in ${A.d_after_revoke.carriers?.join(", ") || "no header"}; tries ${A.d_after_revoke.tries}` : ""),
    "",
    "| Step | ms | ok | note |",
    "|---|---|---|---|",
    ...e.steps.map((s) => `| ${s.step} | ${s.ms} | ${s.ok ? "yes" : "no"} | ${s.note.replace(/\|/g, "/")} |`),
    "",
    `Cleanup: machine ${e.cleanup.machine}, environments ${e.cleanup.environments}, install ${e.cleanup.install}, signed out ${e.cleanup.signedOut}`,
    "",
  ].join("\n")
}

if (import.meta.main) {
  main(parseCli(process.argv.slice(2))).then(
    (code) => process.exit(code),
    (e) => {
      process.stderr.write(`vault-edge-e2e: ${String((e as Error)?.message ?? e).slice(0, 300)}\n`)
      process.exit(2)
    },
  )
}
