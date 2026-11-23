// Tests for router.mjs (no VM, no wrangler): node --test scripts/cmux-next/cloud-dev-stack/test_router.mjs
// A fake stack (an HTTP and WebSocket echo server) stands in for a tag's wrangler.
import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { mkdirSync, mkdtempSync, writeFileSync, statSync, utimesSync } from "node:fs"
import http from "node:http"
import net from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { createRouter, routeFor, wake, wakeArgs, WAKE_TIMEOUT_MS, WAKE_WAIT_S } from "./router.mjs"

/** Close servers and their kept-alive sockets (the router's upstream agent keeps them open). */
const done = (...servers) => servers.forEach((s) => { s.closeAllConnections?.(); s.close() })

const listen = (server) => new Promise((r) => server.listen(0, "127.0.0.1", () => r(server.address().port)))

function fakeStack() {
  const server = http.createServer((req, res) => {
    let body = ""
    req.on("data", (d) => (body += d))
    req.on("end", () => res.end(JSON.stringify({ host: req.headers.host, path: req.url, method: req.method, body })))
  })
  server.on("upgrade", (req, socket) => {
    const accept = createHash("sha1").update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64")
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\nX-Seen-Host: ${req.headers.host}\r\n\r\n`)
    socket.on("data", (d) => socket.write(d)) // raw echo is enough to see bytes cross both ways
    socket.on("end", () => socket.destroy())
    socket.on("error", () => {})
  })
  return server
}

function base(stacks) {
  const dir = mkdtempSync(join(tmpdir(), "wdev-router-"))
  mkdirSync(join(dir, "registry"))
  const routes = {}
  for (const s of stacks) {
    mkdirSync(join(dir, "stacks", s.tag), { recursive: true })
    writeFileSync(join(dir, "registry", `${s.tag}.json`), JSON.stringify({ tag: s.tag, state: s.state }))
    for (const a of s.authorities) routes[a] = { tag: s.tag, port: s.port }
  }
  writeFileSync(join(dir, "routes.json"), JSON.stringify(routes))
  return dir
}

const get = (port, host, path = "/v1/health", method = "GET", body) =>
  new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path, method, headers: { host } }, (res) => {
      let data = ""
      res.on("data", (d) => (data += d))
      res.on("end", () => resolve({ status: res.statusCode, body: data }))
    })
    req.on("error", reject)
    req.end(body)
  })

test("routes by the Host the client used, port included, case-insensitive", () => {
  const table = { "vm.tail.ts.net:4700": { tag: "a", port: 4700 } }
  assert.equal(routeFor(table, "VM.tail.ts.net:4700").tag, "a")
  assert.equal(routeFor(table, "vm.tail.ts.net:4701"), undefined)
  assert.equal(routeFor(table, undefined), undefined)
})

test("a running stack is proxied with the client's Host; an unknown Host is refused", async () => {
  const stack = fakeStack()
  const sport = await listen(stack)
  const dir = base([{ tag: "a", state: "running", port: sport, authorities: ["vm.tail.ts.net:4700", "vm.tail.ts.net:4701"] }])
  const router = createRouter({ base: dir, wakeRun: async () => assert.fail("no wake for a running stack") })
  const rport = await listen(router)
  const r = await get(rport, "vm.tail.ts.net:4701", "/v1/me/macs?x=1")
  assert.equal(r.status, 200)
  assert.deepEqual(JSON.parse(r.body), { host: "vm.tail.ts.net:4701", path: "/v1/me/macs?x=1", method: "GET", body: "" })
  const post = await get(rport, "vm.tail.ts.net:4700", "/v1/ops", "POST", '{"op":"x"}')
  assert.equal(JSON.parse(post.body).body, '{"op":"x"}')
  assert.equal((await get(rport, "other.tail.ts.net:4700")).status, 421)
  assert.ok(statSync(join(dir, "stacks/a/heartbeat")).mtimeMs > 0, "a request is the stack's activity")
  done(router, stack)
})

test("a stopped stack wakes once for every request that waits on it, then serves them all", async () => {
  const stack = fakeStack()
  const sport = await listen(stack)
  const dir = base([{ tag: "s", state: "stopped", port: sport, authorities: ["vm.tail.ts.net:4710"] }])
  let wakes = 0
  const wakeRun = async (tag) => {
    wakes++
    await new Promise((r) => setTimeout(r, 200))
    writeFileSync(join(dir, "registry", `${tag}.json`), JSON.stringify({ tag, state: "running" }))
  }
  const router = createRouter({ base: dir, wakeRun })
  const rport = await listen(router)
  const answers = await Promise.all([1, 2, 3].map(() => get(rport, "vm.tail.ts.net:4710")))
  assert.deepEqual(answers.map((a) => a.status), [200, 200, 200])
  assert.equal(wakes, 1)
  done(router, stack)
})

test("a stack that is gone answers 404 with how to bring it back, and a failed wake 503", async () => {
  const dir = base([
    { tag: "gone", state: "reaped", port: 1, authorities: ["vm.tail.ts.net:4720"] },
    { tag: "bad", state: "stopped", port: 1, authorities: ["vm.tail.ts.net:4730"] },
  ])
  const router = createRouter({ base: dir, wakeRun: async () => { throw new Error("no memory") } })
  const rport = await listen(router)
  const gone = await get(rport, "vm.tail.ts.net:4720")
  assert.equal(gone.status, 404)
  assert.match(gone.body, /cloud-dev-stack\.sh up --tag gone/)
  const bad = await get(rport, "vm.tail.ts.net:4730")
  assert.equal(bad.status, 503)
  assert.match(bad.body, /no memory/)
  done(router)
})

test("a running entry whose workerd is gone is woken and a GET is sent again", async () => {
  const stack = fakeStack()
  const dir = base([{ tag: "c", state: "running", port: 0, authorities: ["vm.tail.ts.net:4740"] }])
  // Its port: free now (refused), listening once the wake ran.
  const probe = net.createServer()
  const port = await listen(probe)
  await new Promise((r) => probe.close(r))
  writeFileSync(join(dir, "routes.json"), JSON.stringify({ "vm.tail.ts.net:4740": { tag: "c", port } }))
  let wakes = 0
  const router = createRouter({ base: dir, wakeRun: async () => { wakes++; await new Promise((r) => stack.listen(port, "127.0.0.1", r)) } })
  const rport = await listen(router)
  const r = await get(rport, "vm.tail.ts.net:4740")
  assert.equal(r.status, 200)
  assert.equal(wakes, 1)
  done(router, stack)
})

test("a WebSocket upgrade crosses the router both ways with the client's Host", async () => {
  const stack = fakeStack()
  const sport = await listen(stack)
  const dir = base([{ tag: "w", state: "running", port: sport, authorities: ["vm.tail.ts.net:4750"] }])
  const router = createRouter({ base: dir, wakeRun: async () => {} })
  const rport = await listen(router)
  const got = await new Promise((resolve, reject) => {
    const sock = net.connect(rport, "127.0.0.1", () => {
      sock.write("GET /v1/ws HTTP/1.1\r\nHost: vm.tail.ts.net:4750\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
    })
    let buf = ""
    sock.on("data", (d) => {
      buf += d
      if (buf.includes("\r\n\r\n") && !buf.includes("ping")) sock.write("ping")
      if (buf.includes("ping")) { sock.destroy(); resolve(buf) }
    })
    sock.on("error", reject)
  })
  assert.match(got, /^HTTP\/1\.1 101/)
  assert.match(got, /X-Seen-Host: vm\.tail\.ts\.net:4750/)
  assert.match(got, /ping$/)
  done(router, stack)
})

test("a public host refuses another tag's build space and serves the stack's public keys", async () => {
  const stack = fakeStack()
  const sport = await listen(stack)
  const dir = base([{ tag: "pub", state: "running", port: sport, authorities: [] }])
  writeFileSync(join(dir, "routes.json"), JSON.stringify({ "api.s1.wdev.cmux.dev": { tag: "pub", port: sport, public: true },
                                                          "vm.tail.ts.net:4760": { tag: "pub", port: sport } }))
  writeFileSync(join(dir, "stacks/pub/public-jwks.json"), '{"keys":[{"kty":"EC","x":"X"}]}')
  const router = createRouter({ base: dir, wakeRun: async () => {} })
  const rport = await listen(router)
  const ask = (host, space, path = "/v1/health") => new Promise((resolve, reject) => {
    const headers = { host, ...(space ? { "x-cmux-build-space": space } : {}) }
    http.get({ host: "127.0.0.1", port: rport, path, headers }, (res) => { let b = ""; res.on("data", (d) => (b += d)); res.on("end", () => resolve({ status: res.statusCode, body: b })) }).on("error", reject)
  })
  assert.equal((await ask("api.s1.wdev.cmux.dev", "dev:pub")).status, 200)
  assert.equal((await ask("api.s1.wdev.cmux.dev")).status, 200, "no build space: the stack decides")
  const other = await ask("api.s1.wdev.cmux.dev", "dev:another-tag")
  assert.equal(other.status, 421)
  assert.match(other.body, /another tag's stack/)
  assert.doesNotMatch(other.body, /pub|another-tag/, "an unauthenticated caller learns no tag name")
  assert.equal((await ask("vm.tail.ts.net:4760", "dev:another-tag")).status, 200, "tailnet use by another tag stays possible")
  const jwks = await ask("api.s1.wdev.cmux.dev", undefined, "/__wdev/jwks")
  assert.deepEqual(JSON.parse(jwks.body), { keys: [{ kty: "EC", x: "X" }] })
  done(router, stack)
})

test("wake() shares one run per tag and starts a new one after it settles", async () => {
  let runs = 0
  const run = () => new Promise((r) => setTimeout(() => { runs++; r() }, 50))
  await Promise.all([wake("t", run), wake("t", run)])
  assert.equal(runs, 1)
  await wake("t", run)
  assert.equal(runs, 2)
})

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

test("a client that leaves mid-response frees the stack's side of the request", async () => {
  let upstreamClosed
  const closed = new Promise((r) => (upstreamClosed = r))
  const stack = http.createServer((req, res) => {
    res.writeHead(200, { "content-type": "text/event-stream" })
    res.write("data: first\n\n") // a stream that never ends on its own (an SSE feed, a long poll)
    res.on("close", () => upstreamClosed(res.writableFinished))
  })
  const sport = await listen(stack)
  const dir = base([{ tag: "ab", state: "running", port: sport, authorities: ["vm.tail.ts.net:4760"] }])
  const router = createRouter({ base: dir, wakeRun: async () => {} })
  const rport = await listen(router)
  await new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port: rport, path: "/v1/stream", headers: { host: "vm.tail.ts.net:4760" } }, (res) => {
      res.once("data", () => { req.destroy(); resolve() })
    })
    req.on("error", () => {})
    req.on("close", resolve)
    req.end()
  })
  const finished = await Promise.race([closed, sleep(2000).then(() => "still open")])
  assert.equal(finished, false, "the stack's response was cut when the client left, not left streaming")
  done(router, stack)
})

test("a client that leaves while its stack wakes is never sent on to the stack", async () => {
  const seen = []
  const stack = http.createServer((req, res) => { seen.push(req.url); res.end("ok") })
  const sport = await listen(stack)
  const dir = base([{ tag: "aw", state: "stopped", port: sport, authorities: ["vm.tail.ts.net:4770"] }])
  const wakeRun = async (tag) => {
    await sleep(300)
    writeFileSync(join(dir, "registry", `${tag}.json`), JSON.stringify({ tag, state: "running" }))
  }
  const router = createRouter({ base: dir, wakeRun })
  const rport = await listen(router)
  const req = http.request({ host: "127.0.0.1", port: rport, path: "/v1/left", headers: { host: "vm.tail.ts.net:4770" } })
  req.on("error", () => {})
  req.end()
  await sleep(100)
  req.destroy()
  await sleep(500) // the wake settled; a request still waiting would have been proxied by now
  assert.deepEqual(seen, [])
  assert.equal((await get(rport, "vm.tail.ts.net:4770", "/v1/after")).status, 200)
  assert.deepEqual(seen, ["/v1/after"])
  done(router, stack)
})

test("an open WebSocket keeps its stack in use with heartbeats until it closes", async () => {
  const stack = fakeStack()
  const sport = await listen(stack)
  const dir = base([{ tag: "hb", state: "running", port: sport, authorities: ["vm.tail.ts.net:4780"] }])
  const beatFile = join(dir, "stacks/hb/heartbeat")
  const router = createRouter({ base: dir, wakeRun: async () => {}, heartbeatMs: 60 })
  const rport = await listen(router)
  const sock = await new Promise((resolve, reject) => {
    const s = net.connect(rport, "127.0.0.1", () => {
      s.write("GET /v1/ws HTTP/1.1\r\nHost: vm.tail.ts.net:4780\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
    })
    s.once("data", () => resolve(s))
    s.on("error", reject)
  })
  const old = Date.now() / 1000 - 3 * 3600 // three hours ago: past the 2 h idle stop
  utimesSync(beatFile, old, old)
  await sleep(300) // no request crosses the socket meanwhile
  assert.ok(statSync(beatFile).mtimeMs / 1000 > old + 3600, "an open socket beats the heartbeat")
  sock.destroy()
  await sleep(100)
  utimesSync(beatFile, old, old)
  await sleep(300)
  assert.ok(Math.abs(statSync(beatFile).mtimeMs / 1000 - old) < 1, "a closed socket stops beating")
  done(router, stack)
})

test("the router kills a wake only after the wake's own wait for health ran out", () => {
  const args = wakeArgs("t")
  assert.deepEqual(args.slice(1), ["wake", "--tag", "t", "--wait", String(WAKE_WAIT_S)])
  assert.ok(WAKE_TIMEOUT_MS >= (WAKE_WAIT_S + 60) * 1000, `${WAKE_TIMEOUT_MS} ms kill vs a ${WAKE_WAIT_S} s wait`)
})

test("a Host naming an object built-in is no route, and the router keeps serving", async () => {
  const stack = fakeStack()
  const sport = await listen(stack)
  const dir = base([{ tag: "pp", state: "running", port: sport, authorities: ["vm.tail.ts.net:4790"] }])
  const router = createRouter({ base: dir, wakeRun: async () => assert.fail("no wake") })
  const rport = await listen(router)
  for (const host of ["__proto__", "constructor", "toString", "hasOwnProperty"]) {
    assert.equal((await get(rport, host)).status, 421, host)
    const ws = await new Promise((resolve) => {
      const s = net.connect(rport, "127.0.0.1", () => s.write(`GET / HTTP/1.1\r\nHost: ${host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`))
      let buf = ""
      s.on("data", (d) => (buf += d))
      s.on("close", () => resolve(buf))
      s.on("error", () => resolve(buf))
    })
    assert.match(ws, /^HTTP\/1\.1 421/, host)
  }
  assert.equal(routeFor({ a: { tag: "a", port: "x" } }, "a"), undefined, "a malformed entry is no route")
  assert.equal((await get(rport, "vm.tail.ts.net:4790")).status, 200, "still serving")
  done(router, stack)
})

test("a WebSocket client that leaves while its crashed stack wakes leaves nothing open upstream", async () => {
  let upstreamConnections = 0
  const stack = fakeStack()
  stack.on("connection", () => upstreamConnections++)
  const dir = base([{ tag: "wl", state: "running", port: 0, authorities: ["vm.tail.ts.net:4795"] }])
  const probe = net.createServer()
  const port = await listen(probe)
  await new Promise((r) => probe.close(r))
  writeFileSync(join(dir, "routes.json"), JSON.stringify({ "vm.tail.ts.net:4795": { tag: "wl", port } }))
  let client
  const router = createRouter({
    base: dir,
    wakeRun: async () => {
      client.destroy() // the client leaves during the wake
      await new Promise((r) => stack.listen(port, "127.0.0.1", r))
      await sleep(50)
    },
  })
  const rport = await listen(router)
  client = net.connect(rport, "127.0.0.1", () => client.write("GET /v1/ws HTTP/1.1\r\nHost: vm.tail.ts.net:4795\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"))
  client.on("error", () => {})
  await sleep(400)
  assert.equal(upstreamConnections, 0, "no upstream socket (and no heartbeat) for a client that left")
  done(router, stack)
})

test("an open path on a public host never wakes its stack or counts as its activity", async () => {
  const stack = fakeStack()
  const sport = await listen(stack)
  const dir = base([{ tag: "op", state: "stopped", port: sport, authorities: [] }])
  writeFileSync(join(dir, "routes.json"), JSON.stringify({ "api.s3.wdev.cmux.dev": { tag: "op", port: sport, public: true },
                                                          "hub.s3.wdev.cmux.dev": { tag: "op", port: sport, public: true } }))
  let wakes = 0
  const wakeRun = async (tag) => { wakes++; writeFileSync(join(dir, "registry", `${tag}.json`), JSON.stringify({ tag, state: "running" })) }
  const router = createRouter({ base: dir, wakeRun })
  const rport = await listen(router)
  const beat = join(dir, "stacks/op/heartbeat")
  for (const [host, path] of [["api.s3.wdev.cmux.dev", "/v1/health"], ["api.s3.wdev.cmux.dev", "/v1/client-config"],
                              ["api.s3.wdev.cmux.dev", "/.well-known/jwks.json"], ["hub.s3.wdev.cmux.dev", "/v1/health?x=1"]]) {
    const r = await get(rport, host, path)
    assert.equal(r.status, 503, `${host}${path}`)
    assert.match(r.body, /signed-in request wakes it/)
  }
  assert.equal(wakes, 0)
  assert.throws(() => statSync(beat), "no heartbeat from an open path")
  assert.equal((await get(rport, "api.s3.wdev.cmux.dev", "/v1/me")).status, 200, "an authenticated path (the gateway checked it) wakes it")
  assert.equal(wakes, 1)
  const old = Date.now() / 1000 - 3 * 3600
  utimesSync(beat, old, old)
  await sleep(10)
  assert.equal((await get(rport, "api.s3.wdev.cmux.dev", "/v1/health")).status, 200, "running: the open path is served")
  assert.ok(Math.abs(statSync(beat).mtimeMs / 1000 - old) < 1, "and still counts as no activity")
  done(router, stack)
})
