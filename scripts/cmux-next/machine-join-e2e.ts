#!/usr/bin/env bun
/**
 * Machine join end to end on the DEVELOPMENT platform, for .github/workflows/machine-join-e2e.yml.
 *
 *   bun scripts/cmux-next/machine-join-e2e.ts --origin https://cmux-platform-development.debussy.workers.dev \
 *     --acpmux PATH --user USER --home DIR --name NAME --evidence FILE --run ID --sha SHA [--bench SCRIPT]
 *     [--share-cmux-rd PATH --viewer-user USER --viewer-home DIR --device-hub URL
 *      [--share-install-script PATH --share-rd-sha256 HEX]]
 *
 * The stack account comes only from this process's environment (CMUX_UITEST_STACK_EMAIL and
 * CMUX_UITEST_STACK_PASSWORD, which the workflow maps from the repo's dev stack secrets). This
 * process signs in, gets a cmux-api-development access token, mints a join token (cmj_) and
 * writes it to `acpmux host join`'s stdin, all in memory. Every token is masked (::add-mask::) the
 * moment it exists. Children get a fixed environment (no secret), argv carries no secret, and
 * nothing secret is written to disk, the log or the evidence. acpmux runs as the disposable OS
 * user (`sudo -n -u USER env -i`), whose home the job deletes afterwards.
 *
 * Steps: mint, join (stdin), daemon in the foreground until a heartbeat under 90 s, status, the
 * platform list entry matched by joinTokenId, consent (both none), credential file mode 600,
 * revoke, status and list show revoked, secret scan, evidence. The machine revoke and the install
 * revoke run in `finally` and on SIGINT/SIGTERM, so every path after the mint revokes.
 * Exit 0 when the evidence says pass, 1 otherwise, 2 for a refused invocation.
 *
 * `--scenario own-machine-parity` runs a different scenario (own-machine-parity.ts: a second Mac joined by sign-in, a chat
 * in a picked folder, a dev server's port, a file, 3 runs, a JSON report); it reads no secret and joins nothing.
 *
 * Share (--share-cmux-rd): while joined, proves a joined headless Linux machine is shared with no
 * step on it (Leo, 2026-11-16: "if you've connected to a headlessly running mini why... would it
 * need anything?"). Nothing runs on the host after the join but its daemon (step 4, as the join
 * line restarts it): the daemon itself runs `~/.local/bin/cmux-rd linux-host enable
 * --non-interactive` with its own home (acpmux share_host/linux.rs), as the joined user, whose
 * user systemd manager runs (lingering, as an ssh login would start it), so the host unit it
 * installs runs as on a real machine. The host is only read: `acpmux share-host status`,
 * `linux-host requests` and the unit's journal. A viewer (another disposable user with its own home
 * and Xvfb, the same account) signs in to the development device hub before the join, waits
 * (SHARE_ONLINE_LIMIT_MS from the daemon's start) for the machine's device to be online and shared,
 * and asks for a view: it must stream and decode a frame within SHARE_FRAME_LIMIT_MS, with no
 * request waiting for a person on the host (`linux-host requests` empty). Then a second account
 * (the guest: CMUX_UITEST_GUEST_STACK_EMAIL and _PASSWORD, its own home under the viewer's) signs
 * in: its list must not show the machine, and the hub must refuse its request for the machine's
 * device id. Once the view streams, a moving scene (x11-apps' `ico`) runs on the host's virtual
 * display, so the picture and the frame rate show a live screen; it starts after the stream did, so
 * it plays no part in the share. The evidence keeps the time to the first decoded frame, the decode
 * rate, Mbit/s, and a PNG of the viewer's display (`frame.png` in the viewer's home, which the
 * workflow uploads beside the evidence).
 *
 * The share's cmux-rd comes one of two ways. By default the run's own build is linked at
 * ~/.local/bin/cmux-rd before the join, which tests the commit. With --share-install-script (the
 * workflow's share_install: channel), nothing is there before the join: right after it, the join
 * line's own cmux-rd step (machine-join.sh, CMUX_JOIN_STEP=cmux-rd, root-owned) installs cmux-rd
 * from the channel, which must leave a regular file whose sha256 is the channel's
 * (--share-rd-sha256). The viewer always uses the run's build.
 */
import { spawn } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

export const DEV_PLATFORM = "https://cmux-platform-development.debussy.workers.dev"
export const DEV_API = "https://cmux-api-development.debussy.workers.dev"
const STACK_API = "https://api.stack-auth.com/api/v1"
// The development Stack project cmux-api-development trusts (backend/apps/api/wrangler.jsonc), and its public client key.
const DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
const DEV_STACK_CLIENT_KEY = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
const USER_AGENT = "cmux-machine-join-e2e/1"
export const HEARTBEAT_LIMIT_S = 90
/** The development device hub (workers/device-hub/wrangler.toml [env.dev]); share mode talks to no other. */
export const DEV_DEVICE_HUB = "https://cmux-device-hub-dev.debussy.workers.dev"
/** From the daemon's start (which sets the host up by itself) to its device listed online and shared on the hub: past the daemon's enable bound (180 s, share_host/linux.rs ENABLE_WAIT) by a minute for the host to sign in. */
export const SHARE_ONLINE_LIMIT_MS = 240_000
/** From the viewer's start (sign-in, request) to its first decoded frame. */
export const SHARE_FRAME_LIMIT_MS = 60_000
/** How long the viewer keeps the stream once it starts, before it stops and reports. */
export const SHARE_HOLD_MS = 5_000
/** The share stage's addition to the run's deadline. */
export const SHARE_LIMIT_MS = 8 * 60_000
/** Where the guest account's viewer keeps its own state: a home of its own inside the viewer's. */
export const GUEST_DIR = "guest"
/** The viewer's own virtual display (the host's starts at :99), the size of the host's (setup.rs). */
export const VIEWER_DISPLAY = ":42"
export const VIEWER_SCREEN = "1920x1080x24"
/** The viewer's display as a PNG, in the viewer's home. */
export const FRAME_FILE = "frame.png"
/** The scene drawn on the host's display once the stream runs: a bouncing solid polyhedron. */
export const HOST_SCENE = ["ico", "-faces", "-geometry", "960x540+480+270"]
/** The host unit's drop-in naming its virtual display (setup.rs host_virtual_drop_in), under the joined user's home. */
export const HOST_VIRTUAL_DROP_IN = ".config/systemd/user/cmux-screen-host.service.d/virtual-display.conf"
/** What `cmux-rd linux-host requests` prints with no viewer waiting. */
export const NO_REQUESTS = "No viewer is waiting."
/** The bench's whole run: a cold and two warm installs of each project. */
export const BENCH_LIMIT_MS = 40 * 60_000

/** The last line of `stdout` that is a JSON object, keeping only numbers, booleans and plain strings. */
export function benchResult(stdout: string): Record<string, unknown> | null {
  for (const line of stdout.split("\n").reverse()) {
    let v: unknown
    try {
      v = JSON.parse(line)
    } catch {
      continue
    }
    if (!v || typeof v !== "object" || Array.isArray(v)) continue
    const out: Record<string, unknown> = {}
    for (const [k, x] of Object.entries(v)) {
      if (!/^[A-Za-z0-9_.-]{1,64}$/.test(k)) continue
      if (typeof x === "number" || typeof x === "boolean") out[k] = x
      else if (typeof x === "string" && /^[A-Za-z0-9 _.:/-]{0,128}$/.test(x)) out[k] = x
    }
    return out
  }
  return null
}
/** A CI machine older than this is an interrupted run's: longer than any run lives (12 min, plus the bench). */
export const STALE_MS = 12 * 60_000 + BENCH_LIMIT_MS + 13 * 60_000
/** After a cancel: the whole cleanup's deadline, and the part of it kept for the revoke request. */
export const CANCEL_BUDGET_MS = 7_500
export const REVOKE_RESERVE_MS = 2_500
/** After a SIGKILL, a child's result comes at most this much later, even if a descendant holds its pipes open. */
export const KILL_GRACE_MS = 500
export const CHILD_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/
const USER = /^[a-z_][a-z0-9_-]{0,31}$/
/** An id from the platform or acpmux (machine, join token, team, label): plain, short, and never token-shaped,
 * since it goes into URLs, log lines and the evidence before or without a mask. Anything else is null. */
export const safeId = (v: unknown): string | null =>
  typeof v === "string" && /^[A-Za-z0-9._-]{1,128}$/.test(v) && !/^\.+$/.test(v) && !/cm[jm]_|^eyJ|bearer/i.test(v) ? v : null

/** A log line that can start no workflow command: no `::` (v2 commands), no `##[` (v1), one line only. */
export const plainLine = (text: string) =>
  text.replace(/[\r\n]+/g, " ").replace(/:(?=:)/g, ": ").replace(/##\[/g, "## [")

export interface Options {
  origin: string
  acpmux: string
  user: string
  home: string
  name: string
  evidence: string
  runId: string
  sha: string
  /** A root-owned script run as the disposable user while the machine is joined (before the revoke), or "". */
  bench?: string
  /** Share mode: the run's root-owned cmux-rd (the joined home's ~/.local/bin/cmux-rd links to it, unless
   * `install`), the viewer's disposable user and home, and the device hub. With `install`, the join line's
   * cmux-rd step (the root-owned machine-join.sh) installs the host's cmux-rd from the channel, whose
   * sha256 for this machine's build is `sha256`. */
  share?: { cmuxRd: string; viewerUser: string; viewerHome: string; hub: string; install?: { joinScript: string; sha256: string } }
}

export interface ChildResult {
  code: number | null
  /** UTF-8 text; with `binary`, one character per byte (latin1). */
  stdout: string
  /** UTF-8 text. */
  stderr: string
}

/** `text`'s UTF-8 bytes, one character per byte: how a held value appears in binary (latin1) output. */
export const byteForm = (text: string) => Buffer.from(text, "utf8").toString("latin1")

export interface Daemon {
  /** Stops the process (SIGTERM, then SIGKILL) and answers what it printed. */
  stop(): Promise<ChildResult>
}

/** A child whose output can be read while it runs. */
export interface Live {
  /** What it printed so far (code null while it runs). */
  output(): ChildResult
  /** SIGTERM (sudo relays it to its command). */
  term(): void
  /** SIGKILL; its result then comes at most KILL_GRACE_MS later. */
  kill(): void
  /** Its result, once it ends. */
  done: Promise<ChildResult>
}

export interface Deps {
  fetch: (url: string, init: RequestInit) => Promise<Response>
  /** Runs argv with exactly `env`, writing `stdin` (then closing it) when given. */
  run(argv: string[], options: { env: Record<string, string>; stdin?: string; timeoutMs: number; signal?: AbortSignal; binary?: boolean }): Promise<ChildResult>
  /** Starts a long-running argv with exactly `env`; stdin is closed. */
  start(argv: string[], options: { env: Record<string, string> }): Daemon
  /** Starts argv with exactly `env`, writes `stdin` and closes it; its output is readable while it runs. */
  spawn(argv: string[], options: { env: Record<string, string>; stdin?: string }): Live
  /** One line of this step's output (the job log). */
  write(line: string): void
  writeFile(path: string, text: string): void
  now(): number
  /** Resolves after `ms`; an aborted `signal` drops the timer (the promise then never settles). */
  sleep(ms: number, signal?: AbortSignal): Promise<void>
  /** A signal that aborts `ms` from now, on the same clock as `now` and `sleep`. */
  timeout(ms: number): AbortSignal
}

export interface Evidence {
  run: { id: string; sha: string }
  hubOrigin: string
  name: string
  machineId: string | null
  teamId: string | null
  joinTokenId: string | null
  joinSeconds: number | null
  status: {
    credentialPresent: boolean | null
    joinIncomplete: boolean | null
    revoked: boolean | null
    hubReachable: boolean | null
    heartbeatAgeSeconds: number | null
  }
  consent: { screen: string | null; control: string | null }
  credentialFileMode: string | null
  list: { machineId: string | null; label: string | null; revoked: boolean; lastHeartbeatPresent: boolean } | null
  secretScan: {
    home: { cmj: number | null; cmm: number | null; credentialFileCmm: number | null }
    log: { cmj: number; cmm: number }
    evidence: { cmj: number; cmm: number }
  }
  revoke: { revokedListed: boolean | null; statusRevoked: boolean | null }
  /** With --bench: its exit code and the last JSON object it printed (numbers and plain strings only). */
  bench?: { code: number | null; result: Record<string, unknown> | null }
  /** With --share-cmux-rd: the zero-touch share. */
  share?: ShareEvidence
  result: "pass" | "fail"
  reason: string
}

/** Times are ms. */
export interface ShareEvidence {
  hub: string
  /** The viewer signed in to the hub with the account (which also lets the machine sign in as it). */
  viewerSignedIn: boolean
  /** Steps the run took on the host after the join, besides starting its daemon and reading: always 0. */
  hostSteps: number
  /** Where the host's cmux-rd came from: the run's build, or the channel through the join line. */
  install: "build" | "channel"
  /** With the channel: what the join line left at ~/.local/bin/cmux-rd (a regular file, the channel's sha256). */
  channelInstall: { regularFile: boolean | null; sha256Matches: boolean | null } | null
  /** How the daemon set the host up, as `acpmux share-host status --json` says it (plain words only). */
  daemonShareHost: { state: string | null; detail: string | null }
  deviceId: string | null
  /** From the daemon's start to the device listed online and shared. */
  deviceOnlineMs: number | null
  /** From the viewer's start (sign-in, request) to its "Streaming" line. */
  streamingMs: number | null
  /** From the viewer's start to its stop with a frame decoded: the first frame came within this. */
  firstFrameWithinMs: number | null
  /** From the viewer's start (sign-in, request, ticket, link) to its "First frame decoded" line (to the 50 ms poll). */
  firstFrameMs: number | null
  /** Whether the scene started on the host's display (null: the host has no virtual display). */
  hostScene: boolean | null
  /** The viewer's display as a PNG while it streamed (FRAME_FILE in the viewer's home). */
  frame: { file: string; bytes: number; width: number; height: number } | null
  /** How the hub admitted the viewer's request. */
  hubApproval: "permission" | "requested" | null
  view: ViewStats | null
  /** The viewer was told to wait for the host's person. */
  hostPrompted: boolean
  /** `linux-host requests` on the host printed that no viewer waits. */
  requestsEmpty: boolean | null
  /** Values of this run's sign-in found in the viewer's home (the guest's included) afterwards. */
  viewerHomeHeld: number | null
  /** The second account: signed in to the hub; whether its list showed the joined machine; and its request
   * for the machine's device id (exit, whether the hub refused it, and the hub's code). */
  guest: { signedIn: boolean; sawMachine: boolean | null; request: { code: number | null; refused: boolean | null; hubCode: string | null } }
}

export interface ViewStats {
  ended: string | null
  connected: boolean
  path: string | null
  seconds: number | null
  frames: number | null
  decoded: number | null
  decodeErrors: number | null
  mbitPerS: number | null
  width: number | null
  height: number | null
  encoder: string | null
  firstFrameMs: number | null
  lumaVariance: number | null
  /** Frames decoded per second from the first decoded frame to the last. */
  decodedFps: number | null
  hubApproval: "permission" | "requested" | null
}

/** A plain short string (no token shape), else null. */
export const plainWord = (v: unknown, max = 64): string | null =>
  typeof v === "string" && v.length <= max && /^[A-Za-z0-9 ._:/()-]*$/.test(v) && !/cm[jm]_|eyJ|bearer|authorization/i.test(v) ? v : null
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? Math.round(v * 1000) / 1000 : null)

/** The `view` object of `cmux-rd view`'s report (its --stats-file, or the last JSON line it printed),
 * reduced to numbers and plain words. */
export function viewStats(text: string): ViewStats | null {
  for (const line of text.split("\n").reverse()) {
    let v: any
    try {
      v = JSON.parse(line)
    } catch {
      continue
    }
    const r = v?.view
    if (!r || typeof r !== "object" || Array.isArray(r)) continue
    return {
      ended: plainWord(r.ended, 120),
      connected: r.connected === true,
      path: plainWord(r.path),
      seconds: num(r.seconds),
      frames: num(r.frames),
      decoded: num(r.decoded),
      decodeErrors: num(r.decode_errors),
      mbitPerS: num(r.mbit_per_s),
      width: num(r.welcome?.width),
      height: num(r.welcome?.height),
      encoder: plainWord(r.welcome?.encoder),
      firstFrameMs: num(r.first_frame_ms),
      lumaVariance: num(r.luma_variance),
      decodedFps: num(r.decoded_fps),
      hubApproval: r.hub_approval === "permission" || r.hub_approval === "requested" ? r.hub_approval : null
    }
  }
  return null
}

/** A PNG's width and height from `od -An -tx1` of its first 24 bytes (signature, IHDR), else null. */
export function pngSize(odText: string): { width: number; height: number } | null {
  const b = odText.split(/\s+/).filter(Boolean).map((x) => Number.parseInt(x, 16))
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
  if (b.length < 24 || b.some(Number.isNaN) || sig.some((x, i) => b[i] !== x)) return null
  if (String.fromCharCode(...b.slice(12, 16)) !== "IHDR") return null
  const be = (i: number) => b[i]! * 0x1000000 + (b[i + 1]! << 16) + (b[i + 2]! << 8) + b[i + 3]!
  const width = be(16)
  const height = be(20)
  return width > 0 && height > 0 ? { width, height } : null
}

export interface ListedDevice {
  id: string
  platform: string
  name: string
  online: boolean
}

/** `cmux-rd view --list`: one `ID  PLATFORM  NAME[  (offline)]` line per shared device. */
export function listedDevices(stdout: string): ListedDevice[] {
  const out: ListedDevice[] = []
  for (const line of stdout.split("\n")) {
    const m = /^(\S+)  (\S+)  (.*?)(  \(offline\))?$/.exec(line.trimEnd())
    const id = safeId(m?.[1])
    if (!m || !id) continue
    out.push({ id, platform: m[2]!, name: m[3]!, online: !m[4] })
  }
  return out
}

/** The device the joined machine registered: its name is the join's, else the one new online `linux` device. */
export function joinedDevice(before: ListedDevice[], now: ListedDevice[], name: string): ListedDevice | undefined {
  const named = now.filter((d) => d.name === name && d.online)
  if (named.length === 1) return named[0]
  const fresh = now.filter((d) => d.online && d.platform === "linux" && !before.some((b) => b.id === d.id))
  return named.length === 0 && fresh.length === 1 ? fresh[0] : undefined
}

class Refused extends Error {}
class Failed extends Error {}

/** The refusal for an invocation, or undefined: the origin is development only, the names are plain. */
export function refusal(opts: Options): string | undefined {
  if (opts.origin !== DEV_PLATFORM) return `origin must be ${DEV_PLATFORM}`
  if (!NAME.test(opts.name)) return "name must be 1-63 letters, digits, dot, underscore or dash"
  if (!/^\d{1,20}$/.test(opts.runId)) return "run must be the numeric run id"
  if (!USER.test(opts.user) || opts.user === "root") return "user must be a plain disposable login name"
  if (!opts.home.startsWith("/") || opts.home.includes("..")) return "home must be an absolute path"
  if (!opts.acpmux.startsWith("/")) return "acpmux must be an absolute path"
  if (!opts.evidence.startsWith("/")) return "evidence must be an absolute path"
  if (opts.bench && (!opts.bench.startsWith("/") || opts.bench.includes(".."))) return "bench must be an absolute path"
  if (opts.share) {
    const sh = opts.share
    if (sh.hub !== DEV_DEVICE_HUB) return `device hub must be ${DEV_DEVICE_HUB}`
    if (!sh.cmuxRd.startsWith("/") || sh.cmuxRd.includes("..")) return "cmux-rd must be an absolute path"
    if (!USER.test(sh.viewerUser) || sh.viewerUser === "root" || sh.viewerUser === opts.user) return "viewer user must be a plain disposable login name, not the joined user"
    if (!sh.viewerHome.startsWith("/") || sh.viewerHome.includes("..") || sh.viewerHome === opts.home) return "viewer home must be an absolute path of its own"
    if (sh.install) {
      if (!sh.install.joinScript.startsWith("/") || sh.install.joinScript.includes("..")) return "the join script must be an absolute path"
      if (!/^[0-9a-f]{64}$/.test(sh.install.sha256)) return "the channel's cmux-rd sha256 must be 64 lowercase hex digits"
    }
  }
  return undefined
}

const count = (text: string, needle: string) => text.split(needle).length - 1

export interface TarEntry {
  /** The path as archived (`./.acpmux/…`), with a GNU long name applied. */
  name: string
  /** `0` a regular file, `5` a directory, `2` a symlink, … */
  type: string
  /** A symlink's target. */
  link: string
  body: string
}

/** The entries of a GNU or ustar archive (bytes as latin1). Throws on a truncated or malformed one. */
export function tarEntries(data: string): TarEntry[] {
  const out: TarEntry[] = []
  const field = (h: string, from: number, to: number) => h.slice(from, to).split("\0")[0]!
  let longName: string | null = null
  let longLink: string | null = null
  for (let off = 0; ; ) {
    if (off + 512 > data.length) throw new Error("archive truncated")
    const h = data.slice(off, off + 512)
    if (/^\0*$/.test(h)) return out
    const sizeText = field(h, 124, 136).trim()
    if (!/^[0-7]+$/.test(sizeText)) throw new Error("archive header malformed")
    const size = parseInt(sizeText, 8)
    if (off + 512 + size > data.length) throw new Error("archive truncated")
    const body = data.slice(off + 512, off + 512 + size)
    off += 512 + Math.ceil(size / 512) * 512
    const type = h[156] === "\0" ? "0" : h[156]!
    if (type === "L") {
      longName = body.split("\0")[0]!
      continue
    }
    if (type === "K") {
      longLink = body.split("\0")[0]!
      continue
    }
    if (type === "x" || type === "g") throw new Error("pax archives are not read here")
    const prefix = h.slice(257, 262) === "ustar" ? field(h, 345, 500) : ""
    const name = longName ?? (prefix ? `${prefix}/${field(h, 0, 100)}` : field(h, 0, 100))
    out.push({ name, type, link: longLink ?? field(h, 157, 257), body })
    longName = null
    longLink = null
  }
}

/** A heartbeat time as epoch ms: a number (seconds below 1e11, else ms), a digit string the same way, or RFC 3339. */
export const heartbeatMs = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d{1,16}$/.test(v) ? Number(v) : null
  if (n !== null) return Number.isFinite(n) && n > 0 ? (n < 100_000_000_000 ? n * 1000 : n) : null
  if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(v)) return null
  const t = Date.parse(v)
  return Number.isFinite(t) ? t : null
}
/** A workflow command's data, escaped as the runner reads it back. */
export const escapeData = (value: string) => value.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A")
const JWT = /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\./g
const TOKENISH = /cm[jm]_[A-Za-z0-9_-]+/g

/** What in `text` must never be in evidence: either prefix, a JWT, a bearer header, or any held secret. */
export function evidenceLeaks(text: string, secrets: ReadonlyArray<string>): string[] {
  const found: string[] = []
  if (text.includes("cmj_")) found.push("join token prefix")
  if (text.includes("cmm_")) found.push("credential prefix")
  if (new RegExp(JWT.source).test(text)) found.push("jwt")
  if (/bearer|authorization/i.test(text)) found.push("auth header")
  // A held value as JSON writes it, too: quotes, backslashes and control characters come out escaped.
  if (secrets.some((s) => s.length >= 4 && (text.includes(s) || text.includes(JSON.stringify(s).slice(1, -1))))) found.push("held secret")
  return found
}

/** `text` with every held secret, token, credential and JWT replaced. */
export function redact(text: string, secrets: ReadonlyArray<string>): string {
  let out = text
  for (const s of secrets) if (s.length >= 4) out = out.split(s).join("[secret]")
  return out.replace(TOKENISH, (m) => `${m.slice(0, 4)}[redacted]`).replace(JWT, "[jwt].")
}

/** GNU tar's warning for a socket it does not archive: `tar: ./PATH: socket ignored`. */
export const isSocketSkip = (line: string) => /^tar: .+: socket ignored$/.test(line.trim())
class HomeScanError extends Error {}

const b64u = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("base64url")

/**
 * The whole run. `onCleanup` receives `cancel` as soon as it exists: a signal handler calls it to stop
 * the main flow and run the one cleanup pass (stop the user's processes, revoke the machine, revoke the
 * install, sign out) at once.
 */
export async function runE2E(
  opts: Options,
  env: Record<string, string | undefined>,
  deps: Deps,
  onCleanup?: (cancel: () => Promise<void>) => void
): Promise<Evidence> {
  const secrets: string[] = []
  const transcript: string[] = []
  const childText: string[] = []
  // Every line but this script's own commands is made plain first: an id, a server code or acpmux's
  // output can then never start a workflow command (::stop-commands:: would turn later masks into text).
  const say = (line: string) => {
    const plain = plainLine(line)
    transcript.push(plain)
    deps.write(plain)
  }
  const warn = (text: string) => {
    transcript.push(`::warning::${plainLine(text)}`)
    deps.write(`::warning::${plainLine(text)}`)
  }
  const hold = (value: string) => {
    if (!value) return
    // The runner swallows this command and hides the value everywhere after it. The value is escaped as
    // a workflow command's data (% CR LF), and each line of a multi-line value is masked on its own too.
    // Held in both forms: as text (UTF-8 child output, the log) and as its UTF-8 bytes one per character
    // (the home scan's archive), which differ for a non-ASCII value. Both are masked and matched.
    for (const form of new Set([value, byteForm(value)])) {
      deps.write(`::add-mask::${escapeData(form)}`)
      for (const line of form.split(/\r?\n|\r/)) if (line && line !== form) deps.write(`::add-mask::${escapeData(line)}`)
      secrets.push(form)
    }
  }
  const evidence: Evidence = {
    run: { id: opts.runId, sha: opts.sha },
    hubOrigin: opts.origin,
    name: opts.name,
    machineId: null,
    teamId: null,
    joinTokenId: null,
    joinSeconds: null,
    status: { credentialPresent: null, joinIncomplete: null, revoked: null, hubReachable: null, heartbeatAgeSeconds: null },
    consent: { screen: null, control: null },
    credentialFileMode: null,
    list: null,
    secretScan: { home: { cmj: null, cmm: null, credentialFileCmm: null }, log: { cmj: 0, cmm: 0 }, evidence: { cmj: 0, cmm: 0 } },
    revoke: { revokedListed: null, statusRevoked: null },
    result: "fail",
    reason: ""
  }
  const problems: string[] = []
  const expect = (ok: boolean, what: string) => {
    if (!ok) problems.push(what)
    return ok
  }

  const childEnv = { PATH: CHILD_PATH }
  // Everything runs as the disposable user, reads included: a path that user controls (a symlink, say)
  // reaches nothing beyond what that user could read anyway. Nothing here runs as root.
  const asUserTool = (args: string[]) => [
    "sudo", "-n", "-u", opts.user, "--", "/usr/bin/env", "-i", "-C", opts.home,
    `HOME=${opts.home}`, `USER=${opts.user}`, `LOGNAME=${opts.user}`, `PATH=${CHILD_PATH}`, "LANG=C.UTF-8",
    ...args
  ]
  const asUser = (args: string[]) => asUserTool([opts.acpmux, ...args])
  const credentialFile = `${opts.home}/.acpmux/machine-credential.json`
  // lstat (stat without -L) of the state directory and the credential file: the user's own directory (not a
  // link, so the file is inside the home, whose root-owned parent the user cannot replace) and the user's own
  // regular file with one link (no hard link to it anywhere else).
  const credentialStat = async () => {
    const stateDir = `${opts.home}/.acpmux`
    const r = await deps.run(asUserTool(["stat", "-c", "%n|%F|%U|%h|%a", "--", stateDir, credentialFile]), { env: childEnv, timeoutMs: 10_000 })
    const [dir, file] = r.stdout.trim().split("\n").map((l) => l.split("|"))
    const own =
      r.code === 0 &&
      dir?.[0] === stateDir && dir[1] === "directory" && dir[2] === opts.user &&
      file?.[0] === credentialFile && /^regular (empty )?file$/.test(file[1] ?? "") && file[2] === opts.user && file[3] === "1"
    return { own, mode: own && /^[0-7]{3,4}$/.test(file?.[4] ?? "") ? file![4]! : null }
  }
  const acpmux = async (args: string[], stdin?: string, signal?: AbortSignal, timeoutMs = 60_000) => {
    // No new process of the disposable user once cleanup has begun (it has stopped them all).
    live()
    const r = await deps.run(asUser(args), { env: childEnv, timeoutMs, ...(stdin === undefined ? {} : { stdin }), ...(signal ? { signal } : {}) })
    childText.push(r.stdout, r.stderr)
    return r
  }
  // acpmux prints one pretty-printed JSON object on stdout (cli/output.rs print_json).
  const lastJson = (text: string): any => {
    const start = text.indexOf("{")
    if (start < 0) return undefined
    try {
      return JSON.parse(text.slice(start))
    } catch {
      return undefined
    }
  }
  // A cancel aborts every request in flight (cleanup's own included; it retries) and sets one absolute
  // deadline, CANCEL_BUDGET_MS after the cancel: every later request ends by it, less `reserve`, the time
  // kept back for the revoke itself. The process exits at 9 s; the runner's grace is SIGINT, then SIGTERM
  // 7.5 s later, then SIGKILL.
  let cancelled = false
  let cancelBy = Infinity
  let reserve = 0
  let inFlight = new AbortController()
  // Resolves on the cancel.
  let wake: () => void = () => undefined
  const woken = new Promise<void>((resolve) => (wake = resolve))
  /** True when `work` settles within `ms` (or before a cancel, when `interruptible`); the timer is dropped either way. */
  const within = async (work: Promise<unknown>, ms: number, interruptible: boolean) => {
    const timer = new AbortController()
    try {
      return await Promise.race([
        work.then(() => true, () => true),
        deps.sleep(ms, timer.signal).then(() => false),
        ...(interruptible ? [woken.then(() => false)] : [])
      ])
    } finally {
      timer.abort()
    }
  }
  /** Waits for `work` up to `long`; after a cancel (one landing meanwhile ends the long wait), up to `short`
   * more. A cancel shortens a wait for a process to stop; it never skips confirming that it stopped. */
  const settle = async (work: Promise<unknown>, short: number, long: number) => {
    if (!cancelled && (await within(work, long, true))) return true
    if (!cancelled) return false
    return within(work, short, false)
  }
  const left = () => cancelBy - reserve - deps.now()
  const budget = () => (cancelled ? Math.max(250, Math.min(3_000, left())) : 20_000)
  // `keep`: a cancel does not abort this request (its own timeout still bounds it), for a request whose
  // effect cleanup must know of to undo it (the install's registration).
  const call = async (url: string, init: { method: string; headers?: Record<string, string>; body?: unknown; keep?: boolean }) => {
    const res = await deps.fetch(url, {
      method: init.method,
      redirect: "error",
      signal: init.keep ? deps.timeout(budget()) : AbortSignal.any([deps.timeout(budget()), inFlight.signal]),
      headers: { "user-agent": USER_AGENT, ...(init.body === undefined ? {} : { "content-type": "application/json" }), ...init.headers },
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) })
    })
    const json = (await res.json().catch(() => ({}))) as any
    return { status: res.status, json }
  }
  // An error names the step, the status and the server's code only (a plain identifier), never a body
  // or message that could echo a value.
  const refusedBy = (step: string, r: { status: number; json: any }) => {
    const code = [r.json?.code, r.json?.error?.code].find((c) => typeof c === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(c) && !/cm[jm]_/.test(c))
    return new Failed(`${step}: HTTP ${r.status}${code ? ` ${code}` : ""}`)
  }

  // Session state, all in memory.
  let stack: { access: string; refresh: string } | undefined
  // Share mode: the guest account's Stack session, in memory only; signed out in cleanup.
  let guestStack: { access: string; refresh: string } | undefined
  let user: string | undefined
  let install: string | undefined
  // The sign-in, install and token stage while it runs; cleanup waits for it before undoing it.
  let authing: Promise<void> | undefined
  let keys: CryptoKeyPair | undefined
  let access: { token: string; expiresAt: number } | undefined
  let token: string | undefined
  let daemon: Daemon | undefined
  let credentialPath: string | undefined
  let machineRevoked = false
  // The join child while it runs; cleanup waits for it, since it may redeem the token at any moment.
  let joining: Promise<ChildResult> | undefined
  let joinStarted = false
  // Settles when the join's process has ended (never, if it never started); stops it on abort.
  let joinSettled: Promise<unknown> = new Promise(() => undefined)
  let joinEnded = false
  const joinStop = new AbortController()
  // Share mode: whether any viewer process ran, its display server and its view while they run, and the
  // lines of the viewer and the host printed with a failure.
  let viewerStarted = false
  let viewerX: Daemon | undefined
  let hostScene: Daemon | undefined
  let viewer: Live | undefined
  const shareLog: string[] = []

  const op = async (name: string, params: unknown, keep = false) => {
    const r = await call(`${DEV_API}/v1/ops`, {
      method: "POST",
      headers: { authorization: `Bearer ${stack!.access}` },
      body: { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" },
      keep
    })
    if (r.status !== 200 || r.json?.ok !== true) throw refusedBy(name, r)
    return r.json.value
  }
  const accessToken = async () => {
    if (access && access.expiresAt - deps.now() > 60_000) return access.token
    const ch = await call(`${DEV_API}/v1/auth/challenge`, { method: "POST", body: { user, install } })
    if (ch.status !== 200 || typeof ch.json?.nonce !== "string") throw refusedBy("auth challenge", ch)
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys!.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const tok = await call(`${DEV_API}/v1/auth/token`, { method: "POST", body: { user, install, nonce: ch.json.nonce, signature: b64u(signature) } })
    if (typeof tok.json?.access_token === "string") hold(tok.json.access_token)
    if (tok.status !== 200 || typeof tok.json?.access_token !== "string") throw refusedBy("auth token", tok)
    access = { token: tok.json.access_token, expiresAt: Number(tok.json.expires_at) || deps.now() + 300_000 }
    return access.token
  }
  /** A fresh stack access token from the session's refresh token (kept on any failure). */
  const refreshStack = async () => {
    if (!stack?.refresh) return
    const r = await call(`${STACK_API}/auth/sessions/current/refresh`, { method: "POST", headers: { ...stackHeaders(), "x-stack-refresh-token": stack.refresh } })
    if (typeof r.json?.access_token === "string") hold(r.json.access_token)
    if (r.status === 200 && typeof r.json?.access_token === "string") stack.access = r.json.access_token
  }
  const platform = async (method: string, path: string, body?: unknown) =>
    call(`${opts.origin}${path}`, { method, headers: { authorization: `Bearer ${await accessToken()}` }, ...(body === undefined ? {} : { body }) })
  const listEntry = async () => {
    const r = await platform("GET", "/v1/machines/credentials")
    if (r.status !== 200 || !Array.isArray(r.json?.machines)) throw refusedBy("list", r)
    return (r.json.machines as any[]).find((m) => m?.joinTokenId === evidence.joinTokenId)
  }
  // One retry: status records a revoke under the join lock, which the daemon's heartbeat may hold for a moment.
  // `by` is an absolute deadline: each read gets only what is left of it (60 s at most), and the one retry
  // (after 1 s) runs only if more than that second is left. A read is killed at `by` and answers at most
  // KILL_GRACE_MS later (realDeps); an answer that comes after `by` does not count.
  const status = async (by = Infinity) => {
    for (let attempt = 0; ; attempt++) {
      const left = by - deps.now()
      if (left <= 0) throw new Failed("status: no time left")
      const r = await acpmux(["host", "join", "--status", "--json"], undefined, undefined, Math.min(60_000, left))
      const s = lastJson(r.stdout)
      const late = deps.now() > by
      if (r.code === 0 && s && !late) return s
      if (late || attempt >= 1 || by - deps.now() <= 1_000) throw new Failed(late ? "status: past its deadline" : `status: exit ${r.code}`)
      await within(new Promise(() => undefined), 1_000, false)
    }
  }

  // Self-healing for a run that was killed before its revoke (a runner lost, SIGKILL): revoke this
  // account's own CI machines (label ci-join-<digits>, minted by this user) still joined STALE_MS
  // after they were made. Never fails the run.
  const sweepStale = async () => {
    try {
      const r = await platform("GET", "/v1/machines/credentials")
      if (r.status !== 200 || !Array.isArray(r.json?.machines)) return
      let swept = 0
      for (const m of r.json.machines as any[]) {
        const made = Date.parse(String(m?.createdAt ?? ""))
        if (m?.revoked !== false || m?.mintedBy !== user || !/^ci-join-\d+(?:-\d+)?$/.test(String(m?.label ?? ""))) continue
        const stale = safeId(m.machineId)
        if (!Number.isFinite(made) || deps.now() - made < STALE_MS || !stale) continue
        const done = await platform("POST", `/v1/machines/credentials/${encodeURIComponent(stale)}/revoke`)
        if (done.status >= 200 && done.status < 300) swept += 1
      }
      if (swept > 0) say(`revoked ${swept} machine(s) an earlier interrupted run left joined`)
    } catch {
      warn("could not sweep earlier runs' machines")
    }
  }

  const revokeMachine = async () => {
    if (machineRevoked || !evidence.joinTokenId || !joinStarted) return
    // A join that failed or was interrupted after the redeem still left a machine: find it by its join
    // token, a few times, since the list may not show it at once (6 reads over about 10 s; after a
    // cancel, reads until the deadline less the revoke's reserve). The join process is already gone
    // here, so no redeem can start later.
    let machineId = evidence.machineId ?? undefined
    reserve = REVOKE_RESERVE_MS
    try {
      for (let attempt = 0; !machineId; attempt++) {
        if (cancelled ? left() < 500 : attempt >= 6) break
        // The 2 s pause between reads ends early on a cancel; after one, pauses are 0.5 s at most.
        if (attempt > 0) {
          // After a cancel, pauses of 0.5 s at most, and no read once a pause would be too short to matter
          // (no back-to-back reads as the deadline nears).
          const pause = cancelled ? Math.min(500, left() - 500) : 2_000
          if (pause < 100) break
          await within(new Promise(() => undefined), pause, !cancelled)
        }
        try {
          const found = safeId((await listEntry())?.machineId)
          if (found) machineId = found
        } catch (e) {
          // After a cancel a read cut short by its budget is not the end: read again while time remains.
          if (!cancelled) throw e
        }
      }
    } finally {
      reserve = 0
    }
    if (!machineId) return
    evidence.machineId = machineId
    const r = await platform("POST", `/v1/machines/credentials/${encodeURIComponent(machineId)}/revoke`)
    if (r.status < 200 || r.status >= 300) throw refusedBy("revoke", r)
    machineRevoked = true
    say(`revoked machine ${machineId}`)
  }

  // Every process the disposable user runs (the join, status, the daemon and its children), and nothing
  // else: `kill -1` run as that user signals exactly that user's processes.
  const killUser = (signal: "TERM" | "KILL") =>
    deps.run(["sudo", "-n", "-u", opts.user, "--", "/bin/kill", `-${signal}`, "-1"], { env: childEnv, timeoutMs: cancelled ? 1_000 : 5_000 })

  // One pass, in this order: no new join or daemon can start (the main flow checks `cleaning`); every
  // process of the disposable user is stopped and awaited; the machine is revoked (found by its join
  // token when the join did not report it); then the run's install is revoked and the session signed out.
  let cleaning: Promise<void> | undefined
  const cleanup = () =>
    (cleaning ??= (async () => {
      const stopping = daemon?.stop()
      daemon = undefined
      if (viewerStarted) {
        // The viewer first (its view, its display server, then every process of the viewer user).
        const v = viewer
        const x = viewerX
        viewer = undefined
        viewerX = undefined
        if (v) {
          v.term()
          if (!(await settle(v.done, 1_000, 15_000))) v.kill()
          await settle(v.done.then((r) => childText.push(r.stdout, r.stderr)), 250, 1_000)
        }
        // The scene on the host's display (the joined user's, also ended with that user's processes below).
        const scene = hostScene
        hostScene = undefined
        if (scene) await settle(scene.stop(), 500, 5_000)
        const xStopping = x?.stop()
        await settle(killViewer("TERM"), 750, 5_000)
        if (xStopping) await settle(xStopping, 500, 5_000)
        await settle(killViewer("KILL"), 750, 5_000)
      }
      if (joinStarted) {
        // The join's launcher itself (sudo relays the TERM, or ends before it starts acpmux), then every
        // process of the user. Each step is confirmed before the next, on short bounds after a cancel
        // (at most 3 s in all), so no join can still redeem once the search for its machine begins.
        joinStop.abort()
        await settle(killUser("TERM"), 750, 5_000)
        await settle(Promise.all([joinSettled, stopping]), 1_500, 10_000)
        await settle(killUser("KILL"), 750, 5_000)
        if (!joinEnded) problems.push("the join process had not stopped before the search for its machine")
      }
      if (stopping) {
        let output: ChildResult | undefined
        await settle(stopping.then((r) => (output = r)), 250, 1_000)
        if (output) childText.push(output.stdout, output.stderr)
      }
      // A cancel that lands during this pass aborts the request in flight: try again, on the cancel's budget.
      for (;;) {
        const before = cancelled
        try {
          await revokeMachine()
          // A run that failed before its own revoke check still proves the revoke here.
          if (machineRevoked && evidence.revoke.revokedListed === null && (!cancelled || left() > 1_000)) evidence.revoke.revokedListed = (await listEntry())?.revoked === true
          break
        } catch (e) {
          if (cancelled && !before && !machineRevoked) continue
          problems.push(e instanceof Failed ? e.message : "revoke failed")
          break
        }
      }
      if (evidence.joinTokenId && joinStarted && !machineRevoked && !evidence.machineId) say("no machine was listed for this join token; nothing to revoke")
      // The auth stage (a registration in flight survives a cancel) gets what is left of the cancel budget,
      // less 1.5 s for the install's revoke and the sign-out. Its private key never leaves this process, so
      // an install whose answer never comes cannot be used.
      if (authing) await settle(authing, Math.max(250, cancelBy - deps.now() - 1_500), 20_000)
      if (install && stack) {
        await op("install.revoke", { install }).then(
          () => say("revoked the run's cmux install"),
          () => warn("could not revoke the run's cmux install")
        )
      }
      for (const session of [stack, guestStack]) {
        if (!session) continue
        await call(`${STACK_API}/auth/sessions/current`, {
          method: "DELETE",
          headers: { ...stackHeaders(), "x-stack-access-token": session.access, "x-stack-refresh-token": session.refresh }
        }).catch(() => undefined)
      }
    })())
  /** A signal or the deadline: stop the main flow and clean up now, on short timeouts. */
  const cancel = () => {
    if (!cancelled) {
      cancelled = true
      cancelBy = deps.now() + CANCEL_BUDGET_MS
      problems.push("cancelled")
    }
    inFlight.abort()
    inFlight = new AbortController()
    wake()
    return cleanup()
  }
  // The main flow stops at these points once cleanup has begun.
  const live = () => {
    if (cleaning) throw new Failed("cancelled before the next step")
  }
  onCleanup?.(cancel)

  // Every process of the viewer's disposable user, and nothing else.
  const killViewer = (signal: "TERM" | "KILL") =>
    deps.run(["sudo", "-n", "-u", opts.share!.viewerUser, "--", "/bin/kill", `-${signal}`, "-1"], { env: childEnv, timeoutMs: cancelled ? 1_000 : 5_000 })
  /** A child's line made plain and redacted, for the log and the evidence. */
  const cleanLine = (line: string) =>
    redact(plainLine(line), secrets)
      .replace(/cm[jm]_\S*/g, "(token)")
      .replace(/eyJ\S*/g, "(jwt)")
      .replace(/bearer|authorization/gi, "(auth)")
      .replace(/[^A-Za-z0-9 ._:;,()/'"=+-]/g, "")
      .trim()
      .slice(0, 200)
  const lastLine = (r: ChildResult | undefined) => cleanLine(`${r?.stderr ?? ""}\n${r?.stdout ?? ""}`.split("\n").filter((l) => l.trim()).pop() ?? "")

  // 6a. The share, while joined. Nothing runs on the host but its daemon; it is only read. The viewer and the
  // guest are another user. `prepareShare` runs before the join, `runShare` once the daemon heartbeats.
  const hostRd = () => `${opts.home}/.local/bin/cmux-rd`
  const guestHome = (sh: NonNullable<Options["share"]>) => `${sh.viewerHome}/${GUEST_DIR}`
  // The viewer's commands, as the viewer user, with `home` as HOME (the guest's is its own).
  const asViewerIn = (sh: NonNullable<Options["share"]>, home: string, args: string[]) => [
    "sudo", "-n", "-u", sh.viewerUser, "--", "/usr/bin/env", "-i", "-C", home,
    `HOME=${home}`, `USER=${sh.viewerUser}`, `LOGNAME=${sh.viewerUser}`, `PATH=${CHILD_PATH}`, "LANG=C.UTF-8", `DISPLAY=${VIEWER_DISPLAY}`,
    ...args
  ]
  /** `cmux-rd view --list` as one account (its access token on stdin only), from `home`. */
  const listAs = async (sh: NonNullable<Options["share"]>, home: string, token: string) => {
    live()
    const r = await deps.run(asViewerIn(sh, home, [sh.cmuxRd, "view", "--list", "--hub", sh.hub, "--stack-token-file", "-"]), {
      env: childEnv,
      stdin: `${token}\n`,
      timeoutMs: 60_000,
      signal: inFlight.signal
    })
    childText.push(r.stdout, r.stderr)
    return { devices: r.code === 0 ? listedDevices(r.stdout) : null, r }
  }
  // The owner viewer's list before the join: it tells the joined machine's new device apart.
  let devicesBefore: ListedDevice[] = []
  // Whether the host unit's journal is worth reading for a failure (the daemon has started).
  let hostLog = false

  const prepareShare = async (sh: NonNullable<Options["share"]>) => {
    const ev: ShareEvidence = {
      hub: sh.hub,
      viewerSignedIn: false,
      hostSteps: 0,
      install: sh.install ? "channel" : "build",
      channelInstall: null,
      daemonShareHost: { state: null, detail: null },
      deviceId: null,
      deviceOnlineMs: null,
      streamingMs: null,
      firstFrameWithinMs: null,
      firstFrameMs: null,
      hostScene: null,
      frame: null,
      hubApproval: null,
      view: null,
      hostPrompted: false,
      requestsEmpty: null,
      viewerHomeHeld: null,
      guest: { signedIn: false, sawMachine: null, request: { code: null, refused: null, hubCode: null } }
    }
    evidence.share = ev
    const pause = (ms: number) => within(new Promise(() => undefined), Math.max(0, ms), true)
    live()
    if (sh.install) {
      // From the channel: nothing at ~/.local/bin/cmux-rd before the join (`ls -d` lists a dangling link too).
      const there = await deps.run(asUserTool(["ls", "-d", "--", hostRd()]), { env: childEnv, timeoutMs: 10_000 })
      if (there.code === 0) throw new Failed("share: ~/.local/bin/cmux-rd is there before the join, so the join's install is not tested")
    } else {
      // The daemon runs ~/.local/bin/cmux-rd (the path the host unit runs): it must be the run's own build.
      const link = await deps.run(asUserTool(["readlink", "-f", "--", hostRd()]), { env: childEnv, timeoutMs: 10_000 })
      if (link.code !== 0 || link.stdout.trim() !== sh.cmuxRd) throw new Failed("share: ~/.local/bin/cmux-rd is not the run's cmux-rd")
    }
    viewerStarted = true
    // The viewer's own display.
    const socket = `/tmp/.X11-unix/X${VIEWER_DISPLAY.slice(1)}`
    const isSocket = async () => (await deps.run(asViewerIn(sh, sh.viewerHome, ["test", "-S", socket]), { env: childEnv, timeoutMs: 10_000 })).code === 0
    if (await isSocket()) throw new Failed(`share: the display ${VIEWER_DISPLAY} is already taken`)
    live()
    viewerX = deps.start(asViewerIn(sh, sh.viewerHome, ["Xvfb", VIEWER_DISPLAY, "-screen", "0", VIEWER_SCREEN, "-nolisten", "tcp"]), { env: childEnv })
    const xBy = deps.now() + 10_000
    while (!(await isSocket())) {
      if (deps.now() >= xBy) throw new Failed(`share: the viewer's Xvfb ${VIEWER_DISPLAY} did not start within 10 s`)
      await pause(250)
      live()
    }
    // The viewer signs in with the account (the token on stdin only) before the join: the hub then knows the
    // account, which the machine's own sign-in needs.
    const first = await listAs(sh, sh.viewerHome, stack!.access)
    ev.viewerSignedIn = first.devices !== null
    if (!first.devices) throw new Failed(`share: the viewer could not sign in to the device hub: ${lastLine(first.r)}`)
    devicesBefore = first.devices
    // The guest: its own Stack session and its own home (the viewer user's, so cleanup ends its processes).
    const email = env.CMUX_UITEST_GUEST_STACK_EMAIL ?? ""
    const password = env.CMUX_UITEST_GUEST_STACK_PASSWORD ?? ""
    const signIn = await call(`${STACK_API}/auth/password/sign-in`, { method: "POST", headers: stackHeaders(), body: { email, password } })
    for (const key of ["access_token", "refresh_token"]) if (typeof signIn.json?.[key] === "string") hold(signIn.json[key])
    if (signIn.status !== 200 || typeof signIn.json?.access_token !== "string") throw refusedBy("guest stack sign-in", signIn)
    guestStack = { access: signIn.json.access_token, refresh: String(signIn.json.refresh_token ?? "") }
    live()
    const made = await deps.run(asViewerIn(sh, sh.viewerHome, ["mkdir", "-m", "700", "--", guestHome(sh)]), { env: childEnv, timeoutMs: 10_000 })
    if (made.code !== 0) throw new Failed("share: the guest's home could not be made")
    say("the viewer and the guest are ready; the host gets nothing after the join but its daemon")
  }

  /** share_install: channel. Right after the join, the join line's own cmux-rd step installs the host's cmux-rd
   * from the channel (as the joined user, the root-owned script); it must leave a regular file with the
   * channel's sha256 where the daemon looks. Part of the join, so before the daemon starts. */
  const installFromChannel = async (install: NonNullable<NonNullable<Options["share"]>["install"]>) => {
    const ev = evidence.share!
    live()
    const step = await deps.run(asUserTool(["/usr/bin/env", "CMUX_JOIN_STEP=cmux-rd", "CMUX_JOIN_INTERACTIVE=0", "/bin/sh", install.joinScript]), {
      env: childEnv,
      timeoutMs: 180_000,
      signal: inFlight.signal
    })
    childText.push(step.stdout, step.stderr)
    for (const line of `${step.stderr}\n${step.stdout}`.split("\n").filter((l) => l.trim()).slice(-10)) shareLog.push(`join cmux-rd step: ${cleanLine(line)}`)
    live()
    const kind = await deps.run(asUserTool(["stat", "-c", "%F", "--", hostRd()]), { env: childEnv, timeoutMs: 10_000 })
    const sum = await deps.run(asUserTool(["sha256sum", "--", hostRd()]), { env: childEnv, timeoutMs: 60_000 })
    const got = sum.code === 0 ? (sum.stdout.trim().split(/\s+/)[0] ?? "") : ""
    ev.channelInstall = { regularFile: kind.code === 0 && kind.stdout.trim() === "regular file", sha256Matches: got === install.sha256 }
    say(`join's cmux-rd step: exit ${step.code}; ~/.local/bin/cmux-rd ${ev.channelInstall.regularFile ? "is a regular file" : "is not a regular file"}, ${ev.channelInstall.sha256Matches ? "with the channel's sha256" : "not the channel's sha256"}`)
    if (!ev.channelInstall.regularFile || !ev.channelInstall.sha256Matches)
      throw new Failed(`share: the join did not install the channel's cmux-rd at ~/.local/bin/cmux-rd (${lastLine(step) || `exit ${step.code}`})`)
  }

  const runShare = async (sh: NonNullable<Options["share"]>, daemonStartedAt: number) => {
    const ev = evidence.share!
    const pause = (ms: number) => within(new Promise(() => undefined), Math.max(0, ms), true)
    live()
    // Reads on the host see its user manager (runtime directory and bus), as in its login session.
    const id = await deps.run(asUserTool(["id", "-u"]), { env: childEnv, timeoutMs: 10_000 })
    const uid = id.stdout.trim()
    if (id.code !== 0 || !/^\d{1,10}$/.test(uid)) throw new Failed("share: no uid for the joined user")
    const asHost = (args: string[]) =>
      asUserTool(["/usr/bin/env", `XDG_RUNTIME_DIR=/run/user/${uid}`, `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus`, ...args])
    /** A read on the host: `cmux-rd linux-host requests`, never a step that changes it. */
    const readHost = async (args: string[], timeoutMs = 30_000) => {
      live()
      const r = await deps.run(asHost([hostRd(), ...args]), { env: childEnv, timeoutMs, signal: inFlight.signal })
      childText.push(r.stdout, r.stderr)
      return r
    }
    // xwd's dump of the viewer's root as a PNG (ImageMagick), then its size and its IHDR read back.
    const asViewer = (args: string[]) => asViewerIn(sh, sh.viewerHome, args)
    const framePath = `${sh.viewerHome}/${FRAME_FILE}`
    const captureFrame = async (): Promise<ShareEvidence["frame"]> => {
      live()
      const shot = await deps.run(
        asViewer(["/bin/sh", "-c", 'xwd -root -silent -display "$1" | convert xwd:- "png:$2"', "sh", VIEWER_DISPLAY, framePath]),
        { env: childEnv, timeoutMs: 30_000 }
      )
      if (shot.code !== 0) {
        shareLog.push(`frame: ${lastLine(shot)}`)
        return null
      }
      const size = await deps.run(asViewer(["stat", "-c", "%s", "--", framePath]), { env: childEnv, timeoutMs: 10_000 })
      const head = await deps.run(asViewer(["od", "-An", "-v", "-tx1", "-N", "24", "--", framePath]), { env: childEnv, timeoutMs: 10_000 })
      const ihdr = pngSize(head.code === 0 ? head.stdout : "")
      const bytes = Number(size.stdout.trim())
      if (size.code !== 0 || !Number.isSafeInteger(bytes) || bytes <= 0 || !ihdr) return null
      return { file: FRAME_FILE, bytes, ...ihdr }
    }
    hostLog = true
    try {
      // The machine's device, online and shared, with no step on the host: the daemon sets it up by itself.
      const onlineBy = daemonStartedAt + SHARE_ONLINE_LIMIT_MS
      let device: ListedDevice | undefined
      for (;;) {
        const now = (await listAs(sh, sh.viewerHome, stack!.access)).devices
        device = now ? joinedDevice(devicesBefore, now, opts.name) : undefined
        if (device || deps.now() >= onlineBy) break
        await pause(Math.min(3_000, onlineBy - deps.now()))
      }
      // What the daemon says of the host it set up (a read of its status).
      const daemonStatus = lastJson((await acpmux(["share-host", "status", "--json"], undefined, inFlight.signal, 15_000)).stdout)
      ev.daemonShareHost = { state: plainWord(daemonStatus?.state), detail: plainWord(daemonStatus?.detail, 200) }
      if (ev.daemonShareHost.state) say(`daemon's share host: ${ev.daemonShareHost.state}${ev.daemonShareHost.detail ? ` (${ev.daemonShareHost.detail})` : ""}`)
      if (!device)
        throw new Failed(
          `share: the joined machine's device was not online and shared on the hub within ${SHARE_ONLINE_LIMIT_MS / 1000} s of the daemon's start (daemon's share host: ${ev.daemonShareHost.state ?? "unknown"})`
        )
      ev.deviceId = device.id
      ev.deviceOnlineMs = deps.now() - daemonStartedAt
      say(`device ${device.id} is online and shared ${ev.deviceOnlineMs} ms after the daemon's start`)

      // The view: sign-in, request, ticket, link, stream. It must stream and decode within the limit, and is
      // stopped SHARE_HOLD_MS after it starts streaming, when it writes its report.
      await refreshStack().catch(() => undefined)
      live()
      const statsFile = `${sh.viewerHome}/view-stats.json`
      const startedAt = deps.now()
      const v = (viewer = deps.spawn(
        asViewerIn(sh, sh.viewerHome, [sh.cmuxRd, "view", device.id, "--hub", sh.hub, "--stack-token-file", "-", "--display", VIEWER_DISPLAY, "--stats-file", statsFile, "--scope", "view"]),
        { env: childEnv, stdin: `${stack!.access}\n` }
      ))
      let ended = false
      void v.done.then(() => (ended = true))
      const frameBy = startedAt + SHARE_FRAME_LIMIT_MS
      let streamingAt: number | null = null
      // The host's virtual display, as the drop-in enable wrote names it (a read on the host).
      const dropIn = await deps.run(asUserTool(["cat", "--", `${opts.home}/${HOST_VIRTUAL_DROP_IN}`]), { env: childEnv, timeoutMs: 10_000 })
      const hostDisplay = dropIn.code === 0 ? /\bCMUX_VIRTUAL_DISPLAY=(:\d{1,4})\b/.exec(dropIn.stdout)?.[1] : undefined
      for (;;) {
        const err = v.output().stderr
        if (/Waiting for its person/.test(err)) ev.hostPrompted = true
        if (streamingAt === null && /^Streaming \d+x\d+/m.test(err)) {
          streamingAt = deps.now()
          ev.streamingMs = streamingAt - startedAt
          // The scene, once the host's display is up: something on the screen that moves.
          ev.hostScene = hostDisplay ? !cleaning : null
          if (hostDisplay && !cleaning) hostScene = deps.start(asUserTool(["/usr/bin/env", `DISPLAY=${hostDisplay}`, ...HOST_SCENE]), { env: childEnv })
        }
        if (ev.firstFrameMs === null && /^First frame decoded$/m.test(err)) ev.firstFrameMs = deps.now() - startedAt
        if (ended || ev.hostPrompted || cleaning) break
        const stopAt = streamingAt === null ? frameBy : Math.min(frameBy, streamingAt + SHARE_HOLD_MS)
        if (deps.now() >= stopAt) break
        await within(v.done, Math.min(ev.firstFrameMs === null ? 50 : 250, stopAt - deps.now()), true)
      }
      const stoppedAt = deps.now()
      // The viewer's display while it still shows the stream: xwd of its root, as a PNG in its home.
      if (streamingAt !== null && !ended && !cleaning) ev.frame = await captureFrame()
      viewer = undefined
      v.term()
      const scene = hostScene
      hostScene = undefined
      if (scene) await settle(scene.stop(), 500, 5_000)
      if (!(await settle(v.done, 1_000, 15_000))) v.kill()
      let out: ChildResult | undefined
      await settle(v.done.then((r) => (out = r)), 250, 2_000)
      if (out) childText.push(out.stdout, out.stderr)
      for (const line of (out?.stderr ?? "").split("\n").filter((l) => l.trim()).slice(-30)) shareLog.push(`viewer: ${cleanLine(line)}`)
      live()
      const stats = await deps.run(asViewerIn(sh, sh.viewerHome, ["cat", "--", statsFile]), { env: childEnv, timeoutMs: 10_000 })
      ev.view = viewStats(stats.code === 0 ? stats.stdout : "") ?? viewStats(out?.stderr ?? "")
      ev.hubApproval = ev.view?.hubApproval ?? null
      const decoded = (ev.view?.decoded ?? 0) >= 1
      if (decoded && streamingAt !== null) ev.firstFrameWithinMs = stoppedAt - startedAt
      if (ev.view) say(`view: streaming after ${ev.streamingMs} ms, ${ev.view.decoded} frame(s) decoded, ${ev.view.mbitPerS} Mbit/s, ${ev.view.width}x${ev.view.height}, path ${ev.view.path}`)
      if (ev.view) say(`view: first frame ${ev.firstFrameMs} ms after the request, ${ev.view.decodedFps} fps decoded, picture ${ev.frame ? `${ev.frame.width}x${ev.frame.height} (${ev.frame.bytes} bytes)` : "none"}`)

      // No request reached the host's person.
      const requests = await readHost(["linux-host", "requests"])
      ev.requestsEmpty = requests.code === 0 && requests.stdout.trim() === NO_REQUESTS
      expect(!ev.hostPrompted, "share: the request waited for a person on the host")
      expect(ev.streamingMs !== null, `share: the viewer did not stream within ${SHARE_FRAME_LIMIT_MS / 1000} s${ended && streamingAt === null ? ` (it ended: ${lastLine(out)})` : ""}`)
      expect(ev.firstFrameWithinMs !== null && ev.firstFrameWithinMs <= SHARE_FRAME_LIMIT_MS, `share: no frame decoded within ${SHARE_FRAME_LIMIT_MS / 1000} s of the request`)
      expect(ev.hubApproval === "permission", "share: the hub did not approve the own-account request by permission")
      expect((ev.view?.lumaVariance ?? 0) > 0, "share: the first decoded frame has blank luma")
      expect(ev.requestsEmpty, "share: linux-host requests on the host is not empty")
      expect(ev.frame !== null, "share: no picture of the viewer's display was taken while it streamed")

      // The guest: another account neither sees the machine nor reaches it by its device id.
      const home = guestHome(sh)
      const guestList = await listAs(sh, home, guestStack!.access)
      ev.guest.signedIn = guestList.devices !== null
      if (!guestList.devices) throw new Failed(`share: the guest could not sign in to the device hub: ${lastLine(guestList.r)}`)
      ev.guest.sawMachine = guestList.devices.some((d) => d.id === device.id || d.name === opts.name)
      expect(!ev.guest.sawMachine, "share: the guest account sees the joined machine")
      live()
      const asked = await deps.run(
        asViewerIn(sh, home, [sh.cmuxRd, "view", device.id, "--hub", sh.hub, "--stack-token-file", "-", "--display", VIEWER_DISPLAY, "--scope", "view"]),
        { env: childEnv, stdin: `${guestStack!.access}\n`, timeoutMs: 60_000, signal: inFlight.signal }
      )
      childText.push(asked.stdout, asked.stderr)
      const hubCode = /\(device hub (4\d\d) ([a-z_]{1,64})\)/.exec(asked.stderr)
      ev.guest.request = { code: asked.code, refused: asked.code !== 0 && hubCode !== null, hubCode: hubCode ? `${hubCode[1]} ${hubCode[2]}` : null }
      say(`guest: ${ev.guest.sawMachine ? "sees" : "does not see"} the machine; its request ${ev.guest.request.refused ? `was refused by the hub (${ev.guest.request.hubCode})` : `was not refused by the hub: ${lastLine(asked)}`}`)
      expect(ev.guest.request.refused === true && !/^Streaming /m.test(asked.stderr), "share: the hub did not refuse the guest's request for the joined machine")
    } finally {
      // The host unit's log, for a failure's log only (scanned like every child's output).
      if (hostLog && !cleaning) {
        try {
          const journal = await deps.run(asHost(["journalctl", "--user", "-u", "cmux-screen-host.service", "-o", "cat", "--no-pager", "-n", "60"]), { env: childEnv, timeoutMs: 15_000 })
          childText.push(journal.stdout, journal.stderr)
          for (const line of journal.stdout.split("\n").filter((l) => l.trim()).slice(-40)) shareLog.push(`host: ${cleanLine(line)}`)
        } catch {
          // Only a log.
        }
      }
    }
  }

  const stackHeaders = () => ({ "x-stack-project-id": DEV_STACK_PROJECT, "x-stack-publishable-client-key": DEV_STACK_CLIENT_KEY, "x-stack-access-type": "client" })

  try {
    const why = refusal(opts)
    if (why) throw new Refused(why)
    const email = env.CMUX_UITEST_STACK_EMAIL ?? ""
    const password = env.CMUX_UITEST_STACK_PASSWORD ?? ""
    if (!email || !password) throw new Refused("CMUX_UITEST_STACK_EMAIL and CMUX_UITEST_STACK_PASSWORD must be set")
    if (opts.share) {
      // The share's second account is required: the run proves another account cannot reach the machine.
      const guestEmail = env.CMUX_UITEST_GUEST_STACK_EMAIL ?? ""
      const guestPassword = env.CMUX_UITEST_GUEST_STACK_PASSWORD ?? ""
      if (!guestEmail || !guestPassword) throw new Refused("CMUX_UITEST_GUEST_STACK_EMAIL and CMUX_UITEST_GUEST_STACK_PASSWORD must be set for the share")
      if (guestEmail.trim().toLowerCase() === email.trim().toLowerCase()) throw new Refused("the guest account must be another account than the joining one")
      hold(guestEmail)
      hold(guestPassword)
    }
    hold(email)
    hold(password)

    // 1. Stack sign-in (development project), cmux user, a throwaway install and its access token. Cleanup
    // waits for this (bounded) before it revokes the install and signs out, so a late answer is still undone;
    // after each stage the flow stops if cleanup has begun.
    authing = (async () => {
      const signIn = await call(`${STACK_API}/auth/password/sign-in`, { method: "POST", headers: stackHeaders(), body: { email, password } })
      for (const key of ["access_token", "refresh_token"]) if (typeof signIn.json?.[key] === "string") hold(signIn.json[key])
      if (signIn.status !== 200 || typeof signIn.json?.access_token !== "string") throw refusedBy("stack sign-in", signIn)
      stack = { access: signIn.json.access_token, refresh: String(signIn.json.refresh_token ?? "") }
      say("signed in to the development stack project")
      live()
      user = String((await op("user.ensure", {}))?.id ?? "")
      live()
      keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair
      const jwk = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey
      live()
      install = String(
        (await op("install.register", {
          public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
          kind: "cli",
          name: `machine-join-e2e ${opts.runId}`.slice(0, 80),
          device_name: "machine-join-e2e runner",
          platform: "linux"
          // Kept through a cancel: cleanup must learn the install's id to revoke it.
        }, true))?.id ?? ""
      )
      live()
      await accessToken()
    })()
    await authing
    say("cmux-api-development access token ready")
    live()
    await sweepStale()

    // 1a. The share's viewer and guest, before the join (nothing on the host). Its failure is the run's; the
    // join and its checks still run.
    let shareReady = false
    if (opts.share) {
      try {
        await prepareShare(opts.share)
        shareReady = true
      } catch (e) {
        if (!(e instanceof Failed) || cleaning) throw e
        problems.push(e.message)
      }
    }

    // 2. Mint.
    live()
    // The label is always the run's (the sweep finds a killed run's machine by it); the name is free.
    const mint = await platform("POST", "/v1/machines/join-tokens", { label: `ci-join-${opts.runId}`, ttlSeconds: 600 })
    if (typeof mint.json?.token === "string") hold(mint.json.token)
    if (mint.status !== 200 || typeof mint.json?.token !== "string" || !/^cmj_[A-Za-z0-9_-]{16,4096}$/.test(mint.json.token)) throw refusedBy("mint", mint)
    token = mint.json.token as string
    evidence.joinTokenId = safeId(mint.json.joinTokenId)
    evidence.teamId = safeId(mint.json.teamId)
    // Without its id, a joined machine could not be found to revoke: never join then.
    if (!evidence.joinTokenId || !evidence.teamId) throw new Failed("mint: no joinTokenId or teamId")
    say(`minted join token ${evidence.joinTokenId} for team ${evidence.teamId}`)

    // 3. Join: the token goes to stdin only, then this process drops it.
    live()
    joinStarted = true
    const joinStartedAt = deps.now()
    joining = acpmux(["host", "join", "--hub", opts.origin, "--name", opts.name, "--json"], `${token}\n`, joinStop.signal)
    joinSettled = joining.then(
      () => (joinEnded = true),
      () => (joinEnded = true)
    )
    token = undefined
    const joined = await joining
    joining = undefined
    const j = lastJson(joined.stdout)
    if (joined.code !== 0 || j?.joined !== true) {
      const meaning: Record<number, string> = { 2: "malformed", 3: "expired or used", 4: "hub unreachable", 5: "store failed" }
      throw new Failed(`join: exit ${joined.code}${joined.code !== null && meaning[joined.code] ? ` (${meaning[joined.code]})` : ""}`)
    }
    evidence.machineId = safeId(j.machineId)
    evidence.joinSeconds = Math.max(0, Math.round((deps.now() - joinStartedAt) / 100) / 10)
    if (!evidence.machineId) throw new Failed("join: no valid machineId")
    expect(j.teamId === evidence.teamId, "join team differs from the mint's team")
    say(`joined as machine ${evidence.machineId} in ${evidence.joinSeconds}s`)

    // The stored credential is masked before anything else could print it.
    const pre = await status()
    if (pre.credentialPath !== credentialFile) throw new Failed("status: credential path is not the disposable home's credential file")
    credentialPath = credentialFile
    // The user's own regular file (not a link), read as that user.
    const before = await credentialStat()
    if (!before.own) throw new Failed("credential file is not the disposable user's own regular file, with one link, in its own state directory")
    evidence.credentialFileMode = before.mode
    // 600 from the join itself, not only once the daemon has rewritten the file: a failure here stands.
    expect(before.mode === "600", "credential file mode is not 600 after the join")
    const file = await deps.run(asUserTool(["cat", "--", credentialPath]), { env: childEnv, timeoutMs: 10_000 })
    let record: any
    try {
      record = JSON.parse(file.stdout)
    } catch {
      throw new Failed("credential file is not JSON")
    }
    if (typeof record?.credential === "string") hold(record.credential)
    if (typeof record?.credential !== "string" || !/^cmm_[A-Za-z0-9_-]{16,4096}$/.test(record.credential)) throw new Failed("credential file holds no credential")
    if (record.machine_id !== evidence.machineId) throw new Failed("credential file names another machine")

    // 3a. share_install: channel. The join line's cmux-rd step, part of the join, before the daemon starts.
    // Its failure is the share's: the join's checks still run.
    if (opts.share?.install && shareReady) {
      try {
        await installFromChannel(opts.share.install)
      } catch (e) {
        if (!(e instanceof Failed) || cleaning) throw e
        problems.push(e.message)
        shareReady = false
      }
    }

    // 4. Daemon in the foreground until a heartbeat under the limit.
    live()
    const daemonStartedAt = deps.now()
    daemon = deps.start(asUser(["daemon", "run"]), { env: childEnv })
    const deadline = deps.now() + HEARTBEAT_LIMIT_S * 1000
    let s: any = pre
    let strangeBeat = false
    for (;;) {
      // Status reads (and their retry) end by the heartbeat deadline, so a slow one cannot carry the check past it.
      if (deadline - deps.now() <= 0) break
      s = await status(deadline)
      // acpmux records ms since the epoch on this machine's clock (a string): a beat counts only when it
      // falls in this daemon's first HEARTBEAT_LIMIT_S (1 s of slack before its start), and not in the future.
      const beat = typeof s.lastHeartbeat === "string" && /^\d{1,16}$/.test(s.lastHeartbeat) ? Number(s.lastHeartbeat) : NaN
      if (Number.isFinite(beat) && beat >= daemonStartedAt - 1_000 && beat <= Math.min(deadline, deps.now() + 5_000)) {
        evidence.status.heartbeatAgeSeconds = Math.max(0, Math.round((deps.now() - beat) / 1000))
        if (evidence.status.heartbeatAgeSeconds < HEARTBEAT_LIMIT_S) break
      } else if (s.lastHeartbeat !== null && s.lastHeartbeat !== undefined) strangeBeat = true
      if (deps.now() >= deadline) break
      // The pause ends by the deadline too.
      const pause = Math.min(3_000, deadline - deps.now())
      if (pause <= 0) break
      await within(new Promise(() => undefined), pause, false)
    }
    evidence.status.credentialPresent = s.credentialPresent === true
    evidence.status.joinIncomplete = s.joinIncomplete === true
    evidence.status.revoked = s.revoked === true
    evidence.status.hubReachable = s.hubReachable === true
    // Only the two values acpmux defines; anything else is recorded as null (and fails the consent check).
    const consentValue = (v: unknown) => (v === "none" || v === "granted" ? v : null)
    evidence.consent = { screen: consentValue(s.consent?.screen), control: consentValue(s.consent?.control) }
    expect(evidence.status.credentialPresent, "status: no credential")
    expect(!evidence.status.joinIncomplete, "status: join incomplete")
    expect(!evidence.status.revoked, "status: revoked before the revoke")
    expect(evidence.status.hubReachable, "status: hub unreachable")
    expect(evidence.status.heartbeatAgeSeconds !== null && evidence.status.heartbeatAgeSeconds < HEARTBEAT_LIMIT_S, `no heartbeat within ${HEARTBEAT_LIMIT_S} s${strangeBeat ? " (status showed a heartbeat time outside the daemon's run)" : ""}`)
    expect(s.machineId === evidence.machineId, "status: machine differs from the join's")
    expect(evidence.consent.screen === "none" && evidence.consent.control === "none", "consent is not none for both screen and control")

    // The join's own doctor is the machine-readable readiness receipt. It may return 1 for a
    // signed-out harness or an unavailable optional sandbox, but it must always emit its report.
    const doctor = await acpmux(["host", "doctor", "--here", "--json"], undefined, inFlight.signal, 60_000)
    const doctorLines = doctor.stdout.split("\n").filter((line) => line.trim())
    const doctorReport = doctorLines.map((line) => { try { return JSON.parse(line) } catch { return null } }).find((v: any) => v?.report)
    expect(doctorReport?.report?.steps instanceof Array, "doctor: no machine-readable report")

    // 5. The platform's list, by join token id. Its heartbeat (RFC 3339, or epoch s or ms) must fall in the
    // daemon's run, with a minute's slack for the platform's clock.
    const listedBeatFresh = (v: unknown) => {
      const t = heartbeatMs(v)
      return t !== null && t >= daemonStartedAt - 60_000 && t <= deps.now() + 60_000
    }
    const row = await listEntry()
    if (row) evidence.list = { machineId: safeId(row.machineId), label: safeId(row.label), revoked: row.revoked === true, lastHeartbeatPresent: listedBeatFresh(row.lastHeartbeat) }
    expect(evidence.list?.machineId === evidence.machineId, "list: no entry for this join token")
    expect(evidence.list?.revoked === false, "list: revoked before the revoke")
    expect(evidence.list?.lastHeartbeatPresent === true, "list: no heartbeat")

    // 6. Credential file mode, after the daemon's heartbeat writes: still the user's own regular file.
    const now = await credentialStat()
    evidence.credentialFileMode = now.own ? now.mode : null
    expect(evidence.credentialFileMode === "600", "credential file mode is not 600")

    // 6a. The share (above). Its failure is the run's, and the revoke checks still run after it.
    if (opts.share) {
      try {
        if (shareReady) await runShare(opts.share, daemonStartedAt)
      } catch (e) {
        if (!(e instanceof Failed) || cleaning) throw e
        problems.push(e.message)
      }
    }

    // 6b. The bench, as the disposable user, while the machine is joined and its daemon runs. Its output
    // is redacted and scanned like every other child's; only its last JSON line becomes evidence.
    if (opts.bench) {
      live()
      const r = await deps.run(asUserTool(["/bin/bash", opts.bench, opts.acpmux]), { env: childEnv, timeoutMs: BENCH_LIMIT_MS, signal: inFlight.signal })
      childText.push(r.stdout, r.stderr)
      // The stack session's access token can expire over a long bench; cleanup's install revoke needs it.
      await refreshStack().catch(() => undefined)
      for (const line of r.stdout.split("\n").filter((l) => l.trim()).slice(-60)) say(`  bench: ${redact(plainLine(line), secrets).slice(0, 400)}`)
      evidence.bench = { code: r.code, result: benchResult(r.stdout) }
      expect(r.code === 0 && evidence.bench.result !== null, `bench: exit ${r.code}`)
    }

    // 7. Revoke, then status and list say revoked.
    await revokeMachine()
    const after = await status()
    evidence.revoke.statusRevoked = after.revoked === true
    evidence.revoke.revokedListed = (await listEntry())?.revoked === true
    expect(evidence.revoke.statusRevoked, "status does not show revoked")
    expect(evidence.revoke.revokedListed, "list does not show revoked")
  } catch (e) {
    if (e instanceof Refused) throw e
    problems.unshift(e instanceof Failed ? e.message : `unexpected error (${e instanceof Error ? e.name : "unknown"})`)
  } finally {
    await cleanup()
  }

  // 8. Secret scan: the disposable home (the credential file holds exactly its one credential),
  // everything this step printed and every acpmux process's output.
  try {
    // One process with a fixed argv archives the whole home (names, link targets and contents), so no
    // file name ever reaches an argv. Incomplete is a failure: tar must read everything and exit 0.
    const archive = await deps.run(asUserTool(["tar", "-C", opts.home, "--one-file-system", "--format=gnu", "-cf", "-", "."]), { env: childEnv, timeoutMs: 30_000, binary: true })
    // tar skips what it cannot archive with only a warning and exit 0. A socket is the one entry it may skip:
    // a socket holds no bytes (the share host's, left by its unit when the user's processes are killed), and
    // its name, which tar prints, is scanned below like every other name. Any other word on stderr means the
    // archive is not the whole home, and the failure names it.
    const credentialEntry = `./${credentialFile.slice(opts.home.length + 1)}`
    const warnings = archive.stderr.split("\n").filter((l) => l.trim())
    // Never the credential file's own path: a socket there means the credential is not where it must be.
    const skipped = warnings.filter((l) => !isSocketSkip(l) || l.trim() === `tar: ${credentialEntry}: socket ignored`)
    if (archive.code !== 0 || skipped.length > 0) throw new HomeScanError(`tar ${archive.code !== 0 ? `exit ${archive.code}` : "skipped an entry"}${skipped.length ? `: ${cleanLine(skipped[0])}` : ""}`)
    let cmj = 0
    let cmm = 0
    let held = 0
    for (const line of warnings) {
      cmj += count(line, "cmj_")
      cmm += count(line, "cmm_")
      for (const v of secrets) if (v.length >= 8 && !v.startsWith("cmm_") && line.includes(v)) held += 1
    }
    for (const entry of tarEntries(archive.stdout)) {
      const meta = `${entry.name}\n${entry.link}`
      cmj += count(meta, "cmj_") + count(entry.body, "cmj_")
      cmm += count(meta, "cmm_")
      if (entry.name === credentialEntry && credentialPath) evidence.secretScan.home.credentialFileCmm = count(entry.body, "cmm_")
      else cmm += count(entry.body, "cmm_")
      // Names and bodies are bytes here: `secrets` holds each value's byte form too (see hold).
      for (const v of secrets) if (v.length >= 8 && !v.startsWith("cmm_") && (meta.includes(v) || entry.body.includes(v))) held += 1
    }
    evidence.secretScan.home.cmj = cmj
    evidence.secretScan.home.cmm = cmm
    if (held > 0) problems.push("the home holds a value of this run's sign-in or tokens")
  } catch (e) {
    evidence.secretScan.home.cmj = null
    evidence.secretScan.home.cmm = null
    problems.push(`could not scan the whole disposable home${e instanceof HomeScanError ? ` (${e.message})` : ""}`)
  }
  // The viewer's home: nothing of this run's sign-in (the access token reached the viewer on stdin only).
  if (opts.share && viewerStarted && evidence.share) {
    try {
      const sh = opts.share
      const archive = await deps.run(
        ["sudo", "-n", "-u", sh.viewerUser, "--", "/usr/bin/env", "-i", `PATH=${CHILD_PATH}`, "tar", "-C", sh.viewerHome, "--one-file-system", "--format=gnu", "-cf", "-", "."],
        { env: childEnv, timeoutMs: 30_000, binary: true }
      )
      if (archive.code !== 0) throw new Error("tar failed")
      let held = 0
      for (const entry of tarEntries(archive.stdout)) {
        const text = `${entry.name}\n${entry.link}\n${entry.body}`
        held += count(text, "cmj_") + count(text, "cmm_")
        for (const v of secrets) if (v.length >= 8 && text.includes(v)) held += 1
      }
      evidence.share.viewerHomeHeld = held
    } catch {
      evidence.share.viewerHomeHeld = null
    }
    expect(evidence.share.viewerHomeHeld === 0, "the viewer's home holds a value of this run's sign-in, or could not be scanned")
  }
  const logText = [...transcript, ...childText].join("\n")
  evidence.secretScan.log = { cmj: count(logText, "cmj_"), cmm: count(logText, "cmm_") }
  // An unscanned home is already a problem above; its counts are unknown, not found.
  if (evidence.secretScan.home.cmj !== null) {
    expect(evidence.secretScan.home.cmj === 0, "the home holds a join token")
    if (credentialPath) expect(evidence.secretScan.home.credentialFileCmm === 1, "the credential file does not hold exactly one credential")
    expect(evidence.secretScan.home.cmm === 0, "the home holds a credential outside the credential file")
  }
  expect(evidence.secretScan.log.cmj === 0 && evidence.secretScan.log.cmm === 0, "output holds a token or credential")
  if (secrets.some((s) => s.length >= 4 && logText.includes(s))) problems.push("output holds a secret value")

  evidence.result = problems.length === 0 ? "pass" : "fail"
  evidence.reason =
    problems.length === 0
      ? `joined, heartbeat, listed, consent none, mode 600,${opts.share ? " shared with no step on the host, another account refused," : ""} revoked, no secrets found`
      : problems.join("; ")
  // 9. The evidence itself: scanned before it goes anywhere; a leak replaces it with a bare failure.
  let text = JSON.stringify(evidence, null, 2)
  const leaks = evidenceLeaks(text, secrets)
  evidence.secretScan.evidence = { cmj: count(text, "cmj_"), cmm: count(text, "cmm_") }
  if (leaks.length > 0) {
    const bare: Evidence = { ...evidence, list: null, reason: "evidence redaction check failed", result: "fail", machineId: null, teamId: null, joinTokenId: null, name: "" }
    text = JSON.stringify(bare, null, 2)
    if (evidenceLeaks(text, secrets).length > 0) text = JSON.stringify({ run: evidence.run, result: "fail", reason: "evidence redaction check failed" })
    deps.writeFile(opts.evidence, `${text}\n`)
    say(`machine join e2e: fail (evidence redaction check failed)`)
    return JSON.parse(text)
  }
  text = JSON.stringify(evidence, null, 2)
  deps.writeFile(opts.evidence, `${text}\n`)
  say(`machine join e2e: ${evidence.result}${evidence.result === "fail" ? ` (${redact(evidence.reason, secrets)})` : ""}`)
  if (evidence.result === "fail") {
    // The tail of what acpmux printed, redacted, to debug a failure.
    for (const line of childText.join("\n").split("\n").filter((l) => l.trim()).slice(-40)) say(`  acpmux: ${redact(line, secrets).slice(0, 300)}`)
    for (const line of shareLog) say(`  ${line}`)
  }
  return evidence
}

export function parseArgs(argv: string[]): Options {
  const value = (flag: string) => {
    const i = argv.indexOf(flag)
    return i >= 0 && i + 1 < argv.length ? argv[i + 1]! : ""
  }
  return {
    origin: value("--origin"),
    acpmux: value("--acpmux"),
    user: value("--user"),
    home: value("--home"),
    name: value("--name"),
    evidence: value("--evidence"),
    runId: value("--run"),
    sha: value("--sha"),
    bench: value("--bench"),
    ...(argv.includes("--share-cmux-rd")
      ? {
          share: {
            cmuxRd: value("--share-cmux-rd"),
            viewerUser: value("--viewer-user"),
            viewerHome: value("--viewer-home"),
            hub: value("--device-hub"),
            ...(argv.includes("--share-install-script")
              ? { install: { joinScript: value("--share-install-script"), sha256: value("--share-rd-sha256") } }
              : {})
          }
        }
      : {})
  }
}

/** Production dependencies: sudo children with exactly the given environment, output kept in memory. */
export function realDeps(): Deps {
  const collect = (argv: string[], env: Record<string, string>, stdin: string | undefined, binary = false) => {
    const child = spawn(argv[0]!, argv.slice(1), { env, cwd: "/", stdio: ["pipe", "pipe", "pipe"] })
    const out: Buffer[] = []
    const err: Buffer[] = []
    child.stdout.on("data", (b: Buffer) => out.push(b))
    child.stderr.on("data", (b: Buffer) => err.push(b))
    child.stdin.on("error", () => undefined)
    if (stdin !== undefined) child.stdin.write(stdin)
    child.stdin.end()
    // Text is UTF-8, as acpmux and the tools print it, so redaction and masks see the original values;
    // binary output (the scan's archive) keeps every byte as one character.
    const result = (code: number | null): ChildResult => ({
      code,
      stdout: Buffer.concat(out).toString(binary ? "latin1" : "utf8"),
      stderr: Buffer.concat(err).toString("utf8")
    })
    let finish: (r: ChildResult) => void = () => undefined
    const done = new Promise<ChildResult>((resolve) => {
      finish = resolve
      child.on("error", () => resolve({ code: null, stdout: "", stderr: "spawn failed" }))
      child.on("close", (code) => resolve(result(code)))
    })
    // SIGKILL reaches only the launcher (sudo cannot relay it; the user's processes are ended by cleanup's
    // `kill -1` as that user). A descendant may still hold the pipes open, so the result is given at most
    // KILL_GRACE_MS later regardless, as killed (code null), and the pipes are let go.
    const kill = () => {
      child.kill("SIGKILL")
      const grace = setTimeout(() => {
        child.stdout.destroy()
        child.stderr.destroy()
        finish(result(null))
      }, KILL_GRACE_MS)
      void done.then(() => clearTimeout(grace))
    }
    return { child, done, kill, snapshot: () => result(null) }
  }
  return {
    fetch: (url, init) => fetch(url, init),
    run: async (argv, { env, stdin, timeoutMs, signal, binary }) => {
      const { child, done, kill } = collect(argv, env, stdin, binary)
      // The result comes by timeoutMs + KILL_GRACE_MS at the latest.
      const timer = setTimeout(kill, timeoutMs)
      // An abort: SIGTERM (sudo relays it to its command), then SIGKILL a second later.
      let hard: ReturnType<typeof setTimeout> | undefined
      const stop = () => {
        child.kill("SIGTERM")
        hard = setTimeout(kill, 1_000)
      }
      if (signal?.aborted) stop()
      else signal?.addEventListener("abort", stop, { once: true })
      try {
        return await done
      } finally {
        clearTimeout(timer)
        if (hard) clearTimeout(hard)
        signal?.removeEventListener("abort", stop)
      }
    },
    start: (argv, { env }) => {
      const { child, done, kill } = collect(argv, env, undefined)
      return {
        stop: async () => {
          // sudo relays SIGTERM to acpmux; the job's cleanup step kills the user's leftovers.
          child.kill("SIGTERM")
          const hard = setTimeout(kill, 10_000)
          try {
            return await done
          } finally {
            clearTimeout(hard)
          }
        }
      }
    },
    spawn: (argv, { env, stdin }) => {
      const { child, done, kill, snapshot } = collect(argv, env, stdin)
      return { output: snapshot, term: () => void child.kill("SIGTERM"), kill, done }
    },
    write: (line) => process.stdout.write(`${line}\n`),
    writeFile: (path, text) => {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
      writeFileSync(path, text, { mode: 0o600 })
    },
    now: () => Date.now(),
    sleep: (ms, signal) =>
      new Promise((resolve) => {
        const t = setTimeout(resolve, ms)
        signal?.addEventListener("abort", () => clearTimeout(t), { once: true })
      }),
    timeout: (ms) => AbortSignal.timeout(ms)
  }
}

if (import.meta.main && process.argv.includes("--scenario")) {
  // Scenarios other than the join: no stack secret is read or needed (the Macs are signed in by the person).
  const argv = process.argv.slice(2)
  const scenario = argv[argv.indexOf("--scenario") + 1]
  if (scenario !== "own-machine-parity") {
    console.error(`machine-join-e2e: refused: unknown scenario ${scenario}`)
    process.exit(2)
  }
  const m = await import("./own-machine-parity")
  const o = m.parseOptions(argv, process.env)
  if (typeof o === "string") {
    console.error(`machine-join-e2e: refused: ${o}`)
    process.exit(2)
  }
  const real = realDeps()
  const deps: import("./own-machine-parity").Deps = {
    exec: (argv, timeoutMs) => real.run(argv, { env: { PATH: process.env.PATH ?? CHILD_PATH, HOME: process.env.HOME ?? "/" }, timeoutMs }),
    now: real.now,
    sleep: (ms) => real.sleep(ms),
    write: real.write,
    writeFile: real.writeFile
  }
  process.exit(m.exitCode(await m.runScenario(o, deps)))
}

if (import.meta.main) {
  const names = ["CMUX_UITEST_STACK_EMAIL", "CMUX_UITEST_STACK_PASSWORD", "CMUX_UITEST_GUEST_STACK_EMAIL", "CMUX_UITEST_GUEST_STACK_PASSWORD"] as const
  const env: Record<string, string | undefined> = Object.fromEntries(names.map((name) => [name, process.env[name]]))
  // Gone from this process's environment before anything starts; children get a fixed env anyway.
  for (const name of names) delete process.env[name]
  const opts = parseArgs(process.argv.slice(2))
  const why = refusal(opts)
  if (why) {
    console.error(`machine-join-e2e: refused: ${why}`)
    process.exit(2)
  }
  // A cancel or a step timeout (SIGINT, then SIGTERM about 7.5 s later) stops the run and revokes at
  // once; the run then writes its (failed) evidence and exits. 9 s after the first signal it exits anyway.
  // The run's own deadline (12 minutes, under the step's 15; 40 more with --bench, 8 more with share) cancels the same way.
  let cancelNow: (() => Promise<void>) | undefined
  // Handled, not default, for both signals and every repeat: the second one must not kill the cleanup.
  let stopping = false
  const stop = () => {
    if (stopping) return
    stopping = true
    cancelNow?.()
    setTimeout(() => process.exit(130), 9_000).unref()
  }
  for (const sig of ["SIGINT", "SIGTERM"] as const) process.on(sig, stop)
  setTimeout(() => cancelNow?.(), 12 * 60_000 + (opts.bench ? BENCH_LIMIT_MS : 0) + (opts.share ? SHARE_LIMIT_MS : 0)).unref()
  runE2E(opts, env, realDeps(), (cancel) => (cancelNow = cancel)).then(
    (e) => process.exit(e.result === "pass" ? 0 : 1),
    (e) => {
      console.error(`machine-join-e2e: refused: ${e instanceof Error ? e.message : "error"}`)
      process.exit(2)
    }
  )
}
