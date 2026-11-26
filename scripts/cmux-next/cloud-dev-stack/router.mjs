// The dev VM's one front door to every tag stack (scripts/cmux-next/cloud-dev-stack.sh): a reverse proxy on
// 127.0.0.1:3790 that Tailscale Serve sends each stack's tailnet ports to, and that a stopped stack wakes from.
//
// vm_stack.py copies it to <base>/bin/router.mjs and runs it as cmux-wdev-router.service (the pinned node,
// no dependencies). For each request it reads the authority the client used (Serve keeps the client's Host),
// finds the stack that answers on it (<base>/routes.json, written by vm_stack.py), and
//   - a running stack: proxies the request, WebSocket upgrades included, to its wrangler on 127.0.0.1:<port>
//     with the client's Host, which the stack's front Worker routes by;
//   - a stopped stack: wakes it (`vm_stack.py wake`, one at a time per tag; the requests that arrive meanwhile
//     wait for the same wake), then proxies;
//   - a released stack: its entry stays (state reaped) until the next gc, and a request that still reaches the
//     router (its Serve entry is gone, so only one already on its way) answers 404 with what to run.
// A public authority (<svc>.<slot>.wdev.cmux.dev, which only the authenticating gateway reaches through the Cloudflare
// Tunnel) also refuses a request whose build space names another tag (a phone that kept a released stack's origin
// after its slot went to another tag), and serves GET /__wdev/jwks: the stack's public keys, for the gateway.
// Each request counts as the stack's activity (its heartbeat file, at most every 30 s), which the reaper's idle
// stop reads. Nothing here reads a credential or a request body.
import { spawn } from "node:child_process"
import { readFileSync, statSync, utimesSync, closeSync, openSync } from "node:fs"
import http from "node:http"
import { pipeline } from "node:stream"
import { join } from "node:path"

const BASE = process.env.CMUX_WDEV_BASE ?? "/srv/cmux-dev/wrangler"
const LISTEN_PORT = Number(process.env.CMUX_WDEV_ROUTER_PORT ?? 3790)
// The wake's own wait for health (vm_stack.py wake --wait), and the router's kill after it: admission may stop
// other stacks first, and a killed wake puts the stack back to stopped (its SIGTERM handler).
export const WAKE_WAIT_S = Number(process.env.CMUX_WDEV_WAKE_WAIT_S ?? 150)
export const WAKE_TIMEOUT_MS = Math.max(Number(process.env.CMUX_WDEV_WAKE_TIMEOUT_MS ?? 0), (WAKE_WAIT_S + 90) * 1000)
const HEARTBEAT_EVERY_MS = 30_000
const VM_STACK = join(BASE, "bin/vm_stack.py")

let routes = { path: "", mtimeMs: -1, table: {} }
/** The routes table (authority -> {tag, port}), reread when vm_stack.py rewrote it. */
export function loadRoutes(path = join(BASE, "routes.json")) {
  if (routes.path !== path) routes = { path, mtimeMs: -1, table: {} }
  let mtimeMs
  try {
    mtimeMs = statSync(path).mtimeMs
  } catch {
    return {}
  }
  if (mtimeMs !== routes.mtimeMs) {
    try {
      routes = { path, mtimeMs, table: JSON.parse(readFileSync(path, "utf8")) }
    } catch {
      return routes.table // a half-written file: keep the last good table until the next rename
    }
  }
  return routes.table
}

/** The stack that answers on this Host header, or undefined. Only the table's own entries count, and only a
 * well-formed one: a Host of `__proto__` or `constructor` is no route (a plain object's lookup would find a built-in). */
export function routeFor(table, host) {
  if (typeof host !== "string" || !host || !table || !Object.hasOwn(table, host.toLowerCase())) return undefined
  const route = table[host.toLowerCase()]
  return route && typeof route.tag === "string" && /^[a-z0-9-]+$/.test(route.tag) && Number.isInteger(route.port) && route.port > 0
    ? route
    : undefined
}

function stackState(base, tag) {
  try {
    return JSON.parse(readFileSync(join(base, "registry", `${tag}.json`), "utf8")).state
  } catch {
    return undefined
  }
}

const lastBeat = new Map()
function heartbeat(base, tag, every = HEARTBEAT_EVERY_MS) {
  const now = Date.now()
  if (now - (lastBeat.get(tag) ?? 0) < every / 2) return
  lastBeat.set(tag, now)
  const file = join(base, "stacks", tag, "heartbeat")
  try {
    utimesSync(file, now / 1000, now / 1000)
  } catch {
    try {
      closeSync(openSync(file, "a"))
    } catch {}
  }
}

const wakes = new Map()
/** One wake per tag at a time; every request that needs it waits for the same one. */
export function wake(tag, run = runWake) {
  let pending = wakes.get(tag)
  if (!pending) {
    pending = run(tag).finally(() => wakes.delete(tag))
    wakes.set(tag, pending)
  }
  return pending
}

/** The wake's command: its own wait for health is under the router's kill (WAKE_TIMEOUT_MS). */
export const wakeArgs = (tag) => [VM_STACK, "wake", "--tag", tag, "--wait", String(WAKE_WAIT_S)]

function runWake(tag) {
  return new Promise((resolve, reject) => {
    const child = spawn("python3", wakeArgs(tag), { stdio: ["ignore", "ignore", "pipe"] })
    child.on("error", (e) => reject(new Error(`wake did not start: ${e.message}`))) // a failed spawn is a failed wake
    let err = ""
    child.stderr.on("data", (d) => (err = (err + d).slice(-2000)))
    const timer = setTimeout(() => child.kill("SIGTERM"), WAKE_TIMEOUT_MS)
    child.on("close", (code) => {
      clearTimeout(timer)
      if (code === 0) resolve()
      else reject(new Error(err.trim().split("\n").pop() || `wake exited ${code}`))
    })
  })
}

/** Ready to proxy: a running stack now, or a stopped one once it woke. Throws with the reason otherwise. */
async function ready(opts, route) {
  const state = stackState(opts.base, route.tag)
  if (state === "running") return
  if (state === "stopped" || state === "starting" || state === "preparing") {
    await wake(route.tag, opts.wakeRun)
    return
  }
  throw Object.assign(new Error(`the stack ${route.tag} is ${state ?? "gone"}; cloud-dev-stack.sh up --tag ${route.tag} brings it back`), { status: 404 })
}

function refuse(res, status, message) {
  if (res.headersSent || res.destroyed) return res.destroy()
  res.writeHead(status, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" })
  res.end(`${message}\n`)
}

const agent = new http.Agent({ keepAlive: true, maxSockets: 256 })

/** A request with no body: safe to send again after a wake (its upstream never got anything else). */
/** The tag a request's build space names (`X-Cmux-Build-Space: dev:<slug>`), or undefined. */
export function spaceTag(headers) {
  const v = (headers["x-cmux-build-space"] ?? "").trim()
  return v.startsWith("dev:") ? v.slice(4) : undefined
}

/** Why a public request must not reach this stack, or undefined. */
export function publicRefusal(route, headers) {
  if (!route.public) return undefined
  const tag = spaceTag(headers)
  // Names neither tag: anyone on the internet can send this header to an open path.
  return tag !== undefined && tag !== route.tag ? "this origin is another tag's stack (its slot changed hands); run the hand-off again" : undefined
}

/** An open path's request never wakes a stack, and never joins (or fails) a real request's shared wake. */
const openPathWake = () => Promise.reject(new Error("not woken by an open path"))

/** A path the gateway lets through with no credential (gateway/index.js OPEN), on a public host. Anyone can send
 * one, so it never counts as the stack's activity and never wakes it: a stopped stack answers 503 until a
 * signed-in request wakes it. */
export function publicOpenPath(route, req, host) {
  if (!route.public || req.method !== "GET") return false
  const path = (req.url ?? "").split("?")[0]
  const svc = String(host ?? "").toLowerCase().split(".")[0]
  return path === "/v1/health" || (svc === "api" && (path === "/v1/client-config" || path === "/.well-known/jwks.json"))
}

function serveJwks(opts, res, route) {
  let body = '{"keys":[]}'
  try {
    body = readFileSync(join(opts.base, "stacks", route.tag, "public-jwks.json"), "utf8")
  } catch {}
  res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" })
  res.end(body)
}

const bodyless = (req) =>
  ["GET", "HEAD", "OPTIONS"].includes(req.method) && !req.headers["content-length"] && !req.headers["transfer-encoding"]

function proxy(opts, req, res, route, retried = false) {
  const upstream = http.request(
    { host: "127.0.0.1", port: route.port, method: req.method, path: req.url, headers: req.headers, agent },
    (up) => {
      res.writeHead(up.statusCode ?? 502, up.statusMessage, up.headers)
      // Either side going away ends the other: a client that left mid-stream frees the upstream socket, and an
      // upstream that died mid-response (a stop, a reload) ends the client's response instead of hanging it.
      pipeline(up, res, (e) => {
        if (e) {
          up.destroy()
          res.destroy()
        }
      })
    },
  )
  res.on("close", () => {
    if (!res.writableFinished) upstream.destroy()
  })
  upstream.on("error", async (e) => {
    if (!retried && e.code === "ECONNREFUSED" && !res.headersSent && opts.wakeRun === openPathWake) {
      return refuse(res, 503, "the stack is not running; a signed-in request wakes it") // never the shared wake
    }
    if (!retried && e.code === "ECONNREFUSED" && !res.headersSent) {
      // A stack whose workerd is gone though its entry says running (it crashed, the VM rebooted): wake it,
      // then send a bodyless request again; one with a body was already read, so it is answered 503.
      if (!bodyless(req)) {
        wake(route.tag, opts.wakeRun).catch(() => {})
        return refuse(res, 503, `the stack ${route.tag} was not running; it is starting, retry`)
      }
      try {
        await wake(route.tag, opts.wakeRun)
        if (res.destroyed) return // the client left while its stack woke
        return proxy(opts, req, res, route, true)
      } catch (w) {
        return refuse(res, 503, `the stack ${route.tag} did not wake: ${w.message}`)
      }
    }
    refuse(res, 502, `the stack ${route.tag} did not answer: ${e.code ?? e.message}`)
  })
  if (bodyless(req)) upstream.end()
  else req.pipe(upstream)
}

/** An upgraded socket keeps its stack in use: a heartbeat every opts.heartbeatMs (30 s) while it is open, so a
 * device that only holds a WebSocket (the team hub, signaling) is never stopped as idle under it. */
function holdOpen(opts, tag, socket) {
  const every = opts.heartbeatMs ?? HEARTBEAT_EVERY_MS
  const beat = setInterval(() => heartbeat(opts.base, tag, every), every)
  beat.unref()
  socket.once("close", () => clearInterval(beat))
}

/** The largest refusal body an upgrade's answer carries back (a stack's 401 or 421 is a line of JSON or text). */
const REFUSAL_BODY_MAX = 64 * 1024

/** The status line and headers of `res`, for a raw socket, without the ones `skip` names (lower case). */
function statusLines(res, skip = new Set()) {
  const lines = [`HTTP/1.1 ${res.statusCode} ${res.statusMessage ?? ""}`.trimEnd()]
  for (let i = 0; i < res.rawHeaders.length; i += 2) {
    if (!skip.has(res.rawHeaders[i].toLowerCase())) lines.push(`${res.rawHeaders[i]}: ${res.rawHeaders[i + 1]}`)
  }
  return lines
}

const HOP_BY_HOP = new Set(["connection", "keep-alive", "transfer-encoding", "content-length", "upgrade"])

/** A WebSocket upgrade to the stack. Only a 101 joins the client's socket to the stack's; any other answer (401,
 * 404, the front Worker's 421) goes back whole with `connection: close`, and the client's socket ends. Before
 * 2026-11-25 the router piped the two sockets whatever the stack answered: a refused upgrade left the client's
 * kept-alive connection joined to that stack's wrangler, so Tailscale Serve, which pools its connections to the
 * router across every stack port, sent its later requests on it, for any port, to that one stack. A tagged Mac's
 * signaling then got the wrong stack's front Worker ("421 no Worker of this stack answers on <its own port>")
 * on every retry, and its phone never found it. */
function proxyUpgrade(opts, req, socket, clientHead, route, retried = false) {
  let answered = false
  // Its own socket (no agent), the client's headers as they came (rawHeaders keeps their case and order).
  const upstream = http.request({
    host: "127.0.0.1",
    port: route.port,
    method: req.method,
    path: req.url,
    headers: req.rawHeaders,
    setHost: false,
    agent: false,
  })
  const close = () => {
    upstream.destroy()
    socket.destroy()
  }
  upstream.on("upgrade", (res, up, upHead) => {
    answered = true
    if (socket.destroyed) return up.destroy() // the client left before the stack answered: nothing to hold open
    socket.write(statusLines(res).join("\r\n") + "\r\n\r\n")
    if (upHead?.length) socket.write(upHead)
    if (clientHead?.length) up.write(clientHead)
    up.pipe(socket)
    socket.pipe(up)
    holdOpen(opts, route.tag, socket)
    // A WebSocket never half-closes: either side's end or close ends both (an upgraded socket is half-open by default).
    const end = () => {
      up.destroy()
      socket.destroy()
    }
    up.on("error", end)
    up.on("end", end)
    up.on("close", end)
    socket.on("end", end)
    socket.on("close", end)
  })
  upstream.on("response", (res) => {
    answered = true
    const chunks = []
    let size = 0
    res.on("data", (d) => {
      size += d.length
      if (size > REFUSAL_BODY_MAX) return close()
      chunks.push(d)
    })
    res.on("end", () => {
      const body = Buffer.concat(chunks)
      const lines = statusLines(res, HOP_BY_HOP)
      // A 204 or 304 has no body and names no length (RFC 9110 8.6).
      if (res.statusCode !== 204 && res.statusCode !== 304) lines.push(`content-length: ${body.length}`)
      lines.push("connection: close")
      if (!socket.destroyed) {
        socket.end(Buffer.concat([Buffer.from(lines.join("\r\n") + "\r\n\r\n"), body]))
        // Bytes the client sent before the answer (another request, an early frame) are read and dropped, so
        // its end reaches us and the socket closes instead of waiting on unread data.
        socket.resume()
      }
      upstream.destroy() // agent: false already closes it after the response; say so here
    })
    res.on("error", close)
  })
  upstream.on("error", async (e) => {
    if (!answered && !retried && e.code === "ECONNREFUSED" && !socket.destroyed) {
      try {
        await wake(route.tag, opts.wakeRun)
        if (!socket.destroyed) return proxyUpgrade(opts, req, socket, clientHead, route, true)
      } catch {}
    }
    close()
  })
  socket.on("error", close)
  // A client that ends or leaves before the stack answered is gone: no answer, and no retry after a wake.
  socket.on("end", close)
  socket.on("close", () => answered || upstream.destroy())
  upstream.end()
}

/** The router. opts.base: the wrangler base (routes.json, registry/, stacks/); opts.wakeRun(tag): a wake. */
export function createRouter(opts = {}) {
  opts = { base: BASE, wakeRun: runWake, ...opts }
  const table = () => loadRoutes(join(opts.base, "routes.json"))
  const server = http.createServer(async (req, res) => {
    try {
      await handleRequest(req, res)
    } catch (e) {
      refuse(res, 500, `router error: ${e.message}`) // one bad request never takes the router (and every stack's sockets) down
    }
  })
  const handleRequest = async (req, res) => {
    const route = routeFor(table(), req.headers.host)
    if (!route) return refuse(res, 421, `no tag stack answers on ${req.headers.host ?? "(no host)"}`)
    const refused = publicRefusal(route, req.headers)
    if (refused) return refuse(res, 421, refused)
    if (route.public && req.method === "GET" && req.url === "/__wdev/jwks") return serveJwks(opts, res, route)
    if (publicOpenPath(route, req, req.headers.host)) {
      if (stackState(opts.base, route.tag) !== "running") return refuse(res, 503, "the stack is stopped; a signed-in request wakes it")
      return proxy({ ...opts, wakeRun: openPathWake }, req, res, route)
    }
    heartbeat(opts.base, route.tag)
    // A client that leaves while its stack wakes is not sent on: its request never reaches the stack.
    let gone = false
    res.once("close", () => (gone = true))
    try {
      req.pause()
      await ready(opts, route)
      req.resume()
    } catch (e) {
      return refuse(res, e.status ?? 503, e.message)
    }
    if (gone) return
    proxy(opts, req, res, route)
  }
  server.on("upgrade", async (req, socket, head) => {
    // node drops its own error listener from an upgraded socket: a client reset while the stack wakes must not
    // throw out of the router (proxyUpgrade adds the real one).
    socket.on("error", () => {})
    try {
      await handleUpgrade(req, socket, head)
    } catch {
      socket.destroy()
    }
  })
  const handleUpgrade = async (req, socket, head) => {
    const route = routeFor(table(), req.headers.host)
    if (!route || publicRefusal(route, req.headers)) return socket.end("HTTP/1.1 421 Misdirected Request\r\nconnection: close\r\n\r\n")
    // An open path never upgrades on a public host (the gateway sends a credential-free upgrade nowhere): no
    // heartbeat, no wake.
    if (publicOpenPath(route, req, req.headers.host)) return socket.end("HTTP/1.1 503 Service Unavailable\r\nconnection: close\r\n\r\n")
    heartbeat(opts.base, route.tag)
    try {
      await ready(opts, route)
    } catch (e) {
      return socket.end(`HTTP/1.1 ${e.status ?? 503} Unavailable\r\nconnection: close\r\n\r\n`)
    }
    if (socket.destroyed) return // the client left while its stack woke
    proxyUpgrade(opts, req, socket, head, route)
  }
  // Long-lived sockets (the mobile Worker's team hub, the hub's signaling) must not be cut by node's defaults.
  server.requestTimeout = 0
  server.headersTimeout = 60_000
  server.keepAliveTimeout = 65_000
  return server
}

if (import.meta.url === `file://${process.argv[1]}`) {
  createRouter().listen(LISTEN_PORT, "127.0.0.1", () => console.log(`cmux-wdev-router on 127.0.0.1:${LISTEN_PORT}`))
}
