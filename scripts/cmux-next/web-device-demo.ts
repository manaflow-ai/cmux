#!/usr/bin/env bun
/**
 * Recorded demo: a browser tab enrolls its own web device and chats with a hub machine, on the DEVELOPMENT
 * platform, for machine-join-e2e.yml (web_device: true). machine-join-e2e.ts runs it while its machine is joined.
 *
 *   bun scripts/cmux-next/web-device-demo.ts --origin https://cmux-platform-development.debussy.workers.dev \
 *     --acpmux PATH --pane DIR --target HOST/SESSION --name NAME --label LABEL --out DIR   < access token on stdin
 *
 * The hub machine is machine-join-e2e's joined machine (HOST), whose chat (SESSION) runs the stand-in ACP agent
 * (cmux-tui/crates/acpmux/tests/fake_agent.py), which answers a prompt with its text: the model is the only stand-in.
 * This script, as the runner user, in a home of its own:
 *  1. joins a second machine for the same account (the browser's daemon: a join token minted with the access token,
 *     written to `acpmux host join` on stdin), runs its daemon with a loopback WebSocket listener;
 *  2. opens the NEXT agent pane (the shipped bundle, scripts/cmux-next/build-agent-pane-web.sh) in headless Chrome,
 *     served under that listener's origin (Playwright routing), at `#endpoint=…&token=…&session=HOST/SESSION&must`;
 *  3. on the pane's own socket, after its `initialize`, sends `_acpmux/attach` (the control: refused before any
 *     device), then `_acpmux/device_enroll {accessToken, publicKey}` (once; the key pair is made in the page) and
 *     `_acpmux/device_hello {credential}` (on every connection), and only then lets the pane's queued frames through.
 *     The pane does not send these itself yet: this harness does, and says so in its result (`helloBy: harness`);
 *  4. types one prompt with a nonce into the composer and waits for the hub machine's agent to answer with it;
 *  5. writes demo.webm (video), final.png and result.json to --out, then revokes the web device and its own machine.
 *
 * Secrets: the access token comes on stdin only and is held in memory (machine-join-e2e.ts masked it; never printed); the join token goes
 * to acpmux on stdin; the device credential stays in this process and the pane's socket. stdout's last line is one
 * flat JSON object of ids, booleans and times (machine-join-e2e.ts reads it like the bench's).
 */
import { spawn, type ChildProcess } from "node:child_process"
import { mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs"
import { createServer, connect } from "node:net"
import { tmpdir } from "node:os"
import { dirname, extname, join, resolve, sep } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { randomBytes } from "node:crypto"

export const DEV_PLATFORM = "https://cmux-platform-development.debussy.workers.dev"
/** The whole demo, from the second join to the last revoke. */
export const DEMO_LIMIT_MS = 8 * 60_000
/** From the prompt's Enter to the hub machine's answer carrying the nonce. */
export const REPLY_LIMIT_MS = 90_000
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const PLAIN = /^[A-Za-z0-9._-]{1,128}$/

/** A plain id (machine, session, user), never token-shaped; anything else is null. */
export const plainId = (v: unknown): string | null =>
  typeof v === "string" && PLAIN.test(v) && !/^\.+$/.test(v) && !/cm[jm]_|^eyJ|bearer/i.test(v) ? v : null

/** The pane's URL: its page under the daemon's own origin, the daemon's socket, the chat it must open (no fallback chat). */
export function paneUrl(port: number, token: string, target: string): string {
  const fragment = new URLSearchParams({ endpoint: `ws://127.0.0.1:${port}/`, token, session: target, must: "" })
  return `http://127.0.0.1:${port}/agent-pane/index.html#${fragment.toString()}`
}

/** The bundle file a request path names (`/agent-pane/…`), or null: nothing outside the bundle directory. */
export function paneFile(root: string, pathname: string): string | null {
  if (!pathname.startsWith("/agent-pane/")) return null
  let rest: string
  try {
    rest = decodeURIComponent(pathname.slice("/agent-pane/".length))
  } catch {
    return null
  }
  if (rest === "") rest = "index.html"
  if (rest.includes("\0")) return null
  const base = resolve(root)
  const file = resolve(base, rest)
  return file.startsWith(base + sep) ? file : null
}

export const contentType = (file: string): string =>
  ({ ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2", ".wasm": "application/wasm" })[extname(file)] ??
  "application/octet-stream"

const parse = (text: string): any => {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

/** A JSON-RPC error from the daemon: its code, and a message made plain. */
export class RpcError extends Error {
  constructor(readonly code: number | null, message: string) {
    super(message)
  }
}

/**
 * The pane's socket, between the page and the daemon. Frames pass both ways, except: once the page has sent
 * `initialize`, its later frames wait until the daemon has answered it and `ready` (the harness's enroll and
 * hello, through `request`) has settled; and the daemon's answers to the harness's own requests never reach the page.
 */
export class SocketGate {
  private state: "fresh" | "holding" | "open" = "fresh"
  private initId: unknown
  private started = false
  private queue: string[] = []
  private pending = new Map<string, { resolve: (v: any) => void; reject: (e: RpcError) => void }>()
  private seq = 0
  /** The error `ready` ended with, if any (the frames are let through anyway, so the pane shows its own state). */
  failure: unknown

  constructor(
    private readonly toServer: (text: string) => void,
    private readonly toPage: (text: string) => void,
    private readonly ready: (gate: SocketGate) => Promise<void>,
    private readonly observe: (dir: "page" | "daemon", msg: any) => void = () => undefined,
    private readonly prefix = `web-device-demo-${randomBytes(4).toString("hex")}`
  ) {}

  get open(): boolean {
    return this.state === "open"
  }

  fromPage(text: string): void {
    const msg = parse(text)
    this.observe("page", msg)
    if (this.state === "holding") {
      this.queue.push(text)
      return
    }
    this.toServer(text)
    if (this.state === "fresh" && msg?.method === "initialize" && msg.id !== undefined && msg.id !== null) {
      this.initId = msg.id
      this.state = "holding"
    }
  }

  fromServer(text: string): void {
    const msg = parse(text)
    if (msg && typeof msg.id === "string" && msg.method === undefined && this.pending.has(msg.id)) {
      const waiter = this.pending.get(msg.id)!
      this.pending.delete(msg.id)
      if (msg.error) waiter.reject(new RpcError(typeof msg.error.code === "number" ? msg.error.code : null, String(msg.error.message ?? "error").replace(/[^A-Za-z0-9 ._:;,()/"'-]/g, " ").slice(0, 200)))
      else waiter.resolve(msg.result)
      return
    }
    this.observe("daemon", msg)
    this.toPage(text)
    if (this.state === "holding" && !this.started && msg && msg.method === undefined && msg.id === this.initId) {
      this.started = true
      this.ready(this).then(
        () => this.release(),
        (e) => {
          this.failure = e
          this.release()
        }
      )
    }
  }

  /** One request of the harness's own on this socket; its answer goes to the harness only. */
  request(method: string, params: unknown): Promise<any> {
    const id = `${this.prefix}-${++this.seq}`
    const answer = new Promise<any>((resolve, reject) => this.pending.set(id, { resolve, reject }))
    this.toServer(JSON.stringify({ jsonrpc: "2.0", id, method, params }))
    return answer
  }

  /** The socket closed: every request still waiting fails. */
  closed(): void {
    for (const [, w] of this.pending) w.reject(new RpcError(null, "socket closed"))
    this.pending.clear()
  }

  private release(): void {
    this.state = "open"
    const queued = this.queue
    this.queue = []
    for (const text of queued) this.toServer(text)
  }
}

/** True when a daemon frame is the agent's reply text carrying `nonce` (not the echo of the person's own prompt). */
export function replyCarries(msg: any, nonce: string): boolean {
  const update = msg?.method === "session/update" ? msg.params?.update : undefined
  if (!update || update.sessionUpdate !== "agent_message_chunk") return false
  const content = update.content
  const text = typeof content?.text === "string" ? content.text : Array.isArray(content) ? content.map((c: any) => c?.text ?? "").join("") : ""
  return text.includes(nonce)
}

/** The page's public key as `device_enroll` takes it: the P-256 JWK's public members only. */
export function publicKeyParam(jwk: { kty?: string; crv?: string; x?: string; y?: string }): { kty: "EC"; crv: "P-256"; x: string; y: string } {
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.x !== "string" || typeof jwk.y !== "string") throw new Error("not a P-256 public key")
  return { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }
}

/** The result line: only numbers, booleans and plain strings (machine-join-e2e.ts's benchResult keeps no other). */
export interface DemoResult {
  result: "pass" | "fail"
  reason: string
  helloBy: "harness"
  webMachineJoined: boolean
  controlAttachRefused: boolean | null
  controlAttachCode: number | null
  enrolled: boolean
  webDeviceId: string | null
  helloOk: boolean
  helloCount: number
  attachOk: boolean
  promptSent: boolean
  replySeen: boolean
  stopReason: string | null
  firstPaintMs: number | null
  attachedMs: number | null
  replyMs: number | null
  webDeviceRevoked: boolean | null
  webMachineRevoked: boolean | null
}

export const plainReason = (text: string) =>
  text.replace(/[^A-Za-z0-9 _.:/-]/g, " ").replace(/:(?=:)/g, ": ").replace(/\s+/g, " ").trim().slice(0, 128)

export interface Options {
  origin: string
  acpmux: string
  pane: string
  target: string
  name: string
  label: string
  out: string
}

export function parseArgs(argv: string[]): Options {
  const value = (flag: string) => {
    const i = argv.indexOf(flag)
    return i >= 0 && i + 1 < argv.length ? argv[i + 1]! : ""
  }
  return { origin: value("--origin"), acpmux: value("--acpmux"), pane: value("--pane"), target: value("--target"), name: value("--name"), label: value("--label"), out: value("--out") }
}

export function refusal(o: Options): string | undefined {
  if (o.origin !== DEV_PLATFORM) return `origin must be ${DEV_PLATFORM}`
  for (const [k, v] of [["acpmux", o.acpmux], ["pane", o.pane], ["out", o.out]] as const) if (!v.startsWith("/") || v.includes("..")) return `${k} must be an absolute path`
  const [host, session, extra] = o.target.split("/")
  if (extra !== undefined || !plainId(host) || !plainId(session)) return "target must be HOST/SESSION"
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(o.name)) return "name must be 1-63 letters, digits, dot, underscore or dash"
  if (!/^ci-join-\d+-\d+$/.test(o.label)) return "label must be ci-join-RUN-N (an interrupted run's machine is then swept)"
  return undefined
}

const freePort = () =>
  new Promise<number>((resolve, reject) => {
    const s = createServer()
    s.once("error", reject)
    s.listen(0, "127.0.0.1", () => {
      const port = (s.address() as { port: number }).port
      s.close(() => resolve(port))
    })
  })

const listening = (port: number) =>
  new Promise<boolean>((resolve) => {
    const c = connect({ host: "127.0.0.1", port })
    c.once("connect", () => {
      c.destroy()
      resolve(true)
    })
    c.once("error", () => resolve(false))
  })

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

function run(argv: string[], env: Record<string, string>, stdin: string, timeoutMs: number): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    const child = spawn(argv[0]!, argv.slice(1), { env, cwd: env.HOME, stdio: ["pipe", "pipe", "pipe"] })
    const out: Buffer[] = []
    const err: Buffer[] = []
    child.stdout.on("data", (b: Buffer) => out.push(b))
    child.stderr.on("data", (b: Buffer) => err.push(b))
    child.stdin.on("error", () => undefined)
    child.stdin.end(stdin)
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs)
    child.on("error", () => resolve({ code: null, stdout: "", stderr: "spawn failed" }))
    child.on("close", (code) => {
      clearTimeout(timer)
      resolve({ code, stdout: Buffer.concat(out).toString("utf8"), stderr: Buffer.concat(err).toString("utf8") })
    })
  })
}

const lastJson = (text: string): any => {
  const start = text.indexOf("{")
  return start < 0 ? undefined : parse(text.slice(start))
}

export async function runDemo(o: Options, accessToken: string, log: (line: string) => void): Promise<DemoResult> {
  const r: DemoResult = {
    result: "fail", reason: "", helloBy: "harness", webMachineJoined: false, controlAttachRefused: null, controlAttachCode: null,
    enrolled: false, webDeviceId: null, helloOk: false, helloCount: 0, attachOk: false, promptSent: false, replySeen: false,
    stopReason: null, firstPaintMs: null, attachedMs: null, replyMs: null, webDeviceRevoked: null, webMachineRevoked: null
  }
  const problems: string[] = []
  const t0 = Date.now()
  const since = () => Date.now() - t0
  const [host] = o.target.split("/")
  mkdirSync(o.out, { recursive: true, mode: 0o700 })
  // The browser's daemon: its own home (owner-only, under the system temp, whose sticky bit acpmux accepts).
  const base = mkdtempSync(join(tmpdir(), "web-device-demo-"))
  const home = join(base, "home")
  mkdirSync(join(home, ".acpmux"), { recursive: true, mode: 0o700 })
  const env = { HOME: home, PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", LANG: "C.UTF-8" }
  const port = await freePort()
  const wsToken = randomBytes(24).toString("hex")
  writeFileSync(join(home, ".acpmux", "config.json"), JSON.stringify({ websocket: { listen: `127.0.0.1:${port}`, token: wsToken } }), { mode: 0o600 })
  const platform = async (method: string, path: string, body?: unknown) => {
    const res = await fetch(`${o.origin}${path}`, {
      method,
      redirect: "error",
      signal: AbortSignal.timeout(20_000),
      headers: { authorization: `Bearer ${accessToken}`, "user-agent": "cmux-web-device-demo/1", ...(body === undefined ? {} : { "content-type": "application/json" }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    })
    return { status: res.status, json: (await res.json().catch(() => ({}))) as any }
  }
  const revoke = async (id: string) => (await platform("POST", `/v1/machines/credentials/${encodeURIComponent(id)}/revoke`)).status
  let webMachineId: string | null = null
  let joinTokenId: string | null = null
  let daemon: ChildProcess | undefined
  let credential: string | undefined
  let browser: any
  try {
    // 1. The browser's daemon, joined to the same account (a sweep finds an interrupted run's by its label).
    const mint = await platform("POST", "/v1/machines/join-tokens", { label: o.label, ttlSeconds: 600 })
    const joinToken = typeof mint.json?.token === "string" ? (mint.json.token as string) : ""
    joinTokenId = plainId(mint.json?.joinTokenId)
    if (mint.status !== 200 || !/^cmj_[A-Za-z0-9_-]{16,4096}$/.test(joinToken) || !joinTokenId) throw new Error(`mint: HTTP ${mint.status}`)
    const joined = await run([o.acpmux, "host", "join", "--hub", o.origin, "--name", o.name, "--json"], env, `${joinToken}\n`, 60_000)
    const j = lastJson(joined.stdout)
    webMachineId = plainId(j?.machineId)
    if (joined.code !== 0 || j?.joined !== true || !webMachineId) throw new Error(`browser daemon join: exit ${joined.code}`)
    r.webMachineJoined = true
    log(`joined the browser's daemon as machine ${webMachineId}`)
    daemon = spawn(o.acpmux, ["daemon", "run"], { env, cwd: home, stdio: ["ignore", "ignore", "ignore"] })
    for (let i = 0; i < 120 && !(await listening(port)); i++) await sleep(250)
    if (!(await listening(port))) throw new Error("the browser daemon's WebSocket listener never opened")
    log(`browser daemon listening on 127.0.0.1:${port}`)

    // 2. The pane in headless Chrome (the repo's patched chrome-headless-shell when CI fetched one).
    const { chromium } = (await import(pathToFileURL(join(ROOT, "webviews/node_modules/playwright/index.mjs")).href)) as { chromium: any }
    const { useSystemChrome } = await import(pathToFileURL(join(ROOT, "webviews/test/support/systemChrome.ts")).href)
    useSystemChrome(chromium)
    browser = await chromium.launch()
    const context = await browser.newContext({
      viewport: { width: 1100, height: 760 },
      recordVideo: { dir: o.out, size: { width: 1100, height: 760 } },
      colorScheme: "dark",
      permissions: ["local-network-access"]
    })
    await context.route(`http://127.0.0.1:${port}/**`, async (route: any) => {
      const file = paneFile(o.pane, new URL(route.request().url()).pathname)
      let body: Buffer | undefined
      try {
        if (file && statSync(file).isFile()) body = readFileSync(file)
      } catch {
        body = undefined
      }
      await route.fulfill(body ? { status: 200, body, contentType: contentType(file!) } : { status: 404, body: "" })
    })

    // 3. The pane's socket, gated: control attach, enroll (once), hello (every connection), then the pane's own frames.
    const page = await context.newPage()
    const nonce = `wd-${randomBytes(6).toString("hex")}`
    let enrolling: Promise<void> | undefined
    let promptId: unknown
    let attachIds = new Set<unknown>()
    let replied: () => void = () => undefined
    const reply = new Promise<void>((resolve) => (replied = resolve))
    const observe = (dir: "page" | "daemon", msg: any) => {
      if (!msg) return
      if (dir === "page" && msg.method === "_acpmux/attach") attachIds.add(msg.id)
      if (dir === "page" && msg.method === "session/prompt") promptId = msg.id
      if (dir === "daemon" && msg.method === undefined && attachIds.has(msg.id)) {
        attachIds.delete(msg.id)
        if (!msg.error && !r.attachOk) {
          r.attachOk = true
          r.attachedMs = since()
          log(`the pane attached ${o.target} at +${r.attachedMs} ms`)
        }
      }
      if (dir === "daemon" && msg.method === undefined && promptId !== undefined && msg.id === promptId && typeof msg.result?.stopReason === "string") r.stopReason = plainId(msg.result.stopReason)
      if (dir === "daemon" && replyCarries(msg, nonce)) replied()
    }
    const ready = async (gate: SocketGate) => {
      enrolling ??= (async () => {
        try {
          await gate.request("_acpmux/attach", { sessionId: o.target })
          r.controlAttachRefused = false
        } catch (e) {
          r.controlAttachRefused = true
          r.controlAttachCode = e instanceof RpcError ? e.code : null
        }
        log(`control: attach before any device was ${r.controlAttachRefused ? `refused (${r.controlAttachCode})` : "accepted"}`)
        // The key pair is the page's own; only its public half leaves the page.
        const jwk = await page.evaluate(async () => {
          const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair
          ;(globalThis as any).__webDeviceKeys = keys
          return crypto.subtle.exportKey("jwk", keys.publicKey)
        })
        const enrolled = await gate.request("_acpmux/device_enroll", { accessToken, publicKey: publicKeyParam(jwk) })
        if (typeof enrolled?.credential !== "string" || !enrolled.credential) throw new Error("enroll: no credential")
        credential = enrolled.credential as string
        r.webDeviceId = plainId(enrolled.machineId)
        r.enrolled = Boolean(r.webDeviceId)
        log(`enrolled web device ${r.webDeviceId} for user ${plainId(enrolled.userId)}`)
      })()
      await enrolling
      await gate.request("_acpmux/device_hello", { credential })
      r.helloOk = true
      r.helloCount += 1
    }
    await context.routeWebSocket(new RegExp(`^ws://127\\.0\\.0\\.1:${port}/`), (ws: any) => {
      const server = ws.connectToServer()
      const gate = new SocketGate((t) => server.send(t), (t) => ws.send(t), ready, observe)
      ws.onMessage((m: string | Buffer) => gate.fromPage(String(m)))
      server.onMessage((m: string | Buffer) => gate.fromServer(String(m)))
      server.onClose(() => {
        gate.closed()
        ws.close()
      })
      ws.onClose(() => {
        gate.closed()
        server.close()
      })
    })
    await page.goto(paneUrl(port, wsToken, o.target))
    await page.waitForFunction(() => document.querySelectorAll("body *").length > 20, null, { timeout: 60_000 })
    r.firstPaintMs = since()
    for (let i = 0; i < 240 && !r.attachOk; i++) await sleep(250)
    if (!r.attachOk) throw new Error(r.helloOk ? "the pane's attach was not answered" : "no device hello")

    // 4. One prompt, typed into the composer; the hub machine's agent answers with its text.
    const composer = page.locator('[contenteditable="true"], textarea').first()
    await composer.waitFor({ timeout: 30_000 })
    await page.waitForTimeout(1_000)
    await composer.click()
    await page.keyboard.type(`Hello from a browser tab ${nonce}`, { delay: 20 })
    const sentAt = Date.now()
    await page.keyboard.press("Enter")
    r.promptSent = true
    const got = await Promise.race([reply.then(() => true), sleep(REPLY_LIMIT_MS).then(() => false)])
    r.replySeen = got
    if (got) r.replyMs = Date.now() - sentAt
    await page.waitForTimeout(3_000)
    await page.screenshot({ path: join(o.out, "final.png") })
    const video = page.video()
    await context.close()
    if (video) renameSync(await video.path(), join(o.out, "demo.webm"))
    if (!got) throw new Error(`no reply within ${REPLY_LIMIT_MS / 1000} s`)
  } catch (e) {
    problems.push(e instanceof Error ? e.message : "error")
  } finally {
    await browser?.close().catch(() => undefined)
    // 5. The web device and the browser's machine are revoked; the daemon stopped; its home removed.
    if (r.webDeviceId) {
      const s = await revoke(r.webDeviceId).catch(() => 0)
      r.webDeviceRevoked = s >= 200 && s < 300
      if (!r.webDeviceRevoked) problems.push(`web device revoke: HTTP ${s}`)
    }
    if (!webMachineId && joinTokenId) {
      // A join that failed after its redeem still left a machine: find it by its join token.
      const list = await platform("GET", "/v1/machines/credentials").catch(() => undefined)
      webMachineId = plainId((list?.json?.machines as any[] | undefined)?.find((m) => m?.joinTokenId === joinTokenId)?.machineId)
    }
    if (webMachineId) {
      const s = await revoke(webMachineId).catch(() => 0)
      r.webMachineRevoked = s >= 200 && s < 300
      if (!r.webMachineRevoked) problems.push(`browser machine revoke: HTTP ${s}`)
    }
    if (daemon && daemon.exitCode === null) {
      daemon.kill("SIGTERM")
      await Promise.race([new Promise((res) => daemon!.once("exit", res)), sleep(10_000)])
      if (daemon.exitCode === null && daemon.signalCode === null) daemon.kill("SIGKILL")
    }
    rmSync(base, { recursive: true, force: true })
  }
  if (r.controlAttachRefused === false) problems.push(`control attach to ${host}'s chat was accepted before any device hello`)
  if (!r.helloOk) problems.push("no device hello")
  r.result = problems.length === 0 ? "pass" : "fail"
  r.reason = plainReason(problems.length === 0 ? "enrolled a web device, hello, attached, prompt answered" : problems.join("; "))
  writeFileSync(join(o.out, "result.json"), `${JSON.stringify(r, null, 2)}\n`, { mode: 0o600 })
  return r
}

if (import.meta.main) {
  const o = parseArgs(process.argv.slice(2))
  const why = refusal(o)
  if (why) {
    console.error(`web-device-demo: refused: ${why}`)
    process.exit(2)
  }
  const accessToken = readFileSync(0, "utf8").trim()
  if (!accessToken) {
    console.error("web-device-demo: refused: no access token on stdin")
    process.exit(2)
  }
  // stdout is machine-join-e2e.ts's, which scans it for cmj_ and cmm_ and prints it only made plain: no secret is ever written here.
  const log = (line: string) => process.stdout.write(`${line.replace(/::/g, ": :")}\n`)
  setTimeout(() => {
    console.error("web-device-demo: past its deadline")
    process.exit(1)
  }, DEMO_LIMIT_MS).unref()
  runDemo(o, accessToken, log).then(
    (r) => {
      process.stdout.write(`${JSON.stringify(r)}\n`)
      process.exit(r.result === "pass" ? 0 : 1)
    },
    (e) => {
      console.error(`web-device-demo: ${plainReason(e instanceof Error ? e.message : "error")}`)
      process.exit(1)
    }
  )
}
