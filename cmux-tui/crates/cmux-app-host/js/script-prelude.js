// cmux script prelude (plans/cmux-next/scripting-runtime.md, phase 1).
//
// Evaluated as part of a script session's `main`, after the app runtime
// (dist/cmux-app-runtime.js), acorn and the REPL cell host
// (cmux-browser-host/js/repl-host.js). It exports one command, `eval`, which
// runs one cell: top-level await, top-level declarations kept across cells,
// and the value of the last expression statement as the result.
//
// The VM is untrusted: every op a cell calls through `cmux` goes back to the
// daemon, which checks and routes it. Nothing here is a security boundary.
(function (root) {
  "use strict"
  const replHost = root.CmuxBrowserRepl && root.CmuxBrowserRepl.replHost
  if (!replHost) throw new Error("the REPL cell host is not loaded")
  // Cells must not build a second REPL session over this VM.
  delete root.CmuxBrowserRepl

  // The global `cmux` is a proxy that only reads (the app runtime's compat
  // layer); script members live in `extras`, consulted first.
  const base = root.cmux
  const CmuxError = root.CmuxError
  const extras = Object.create(null)
  const cmux = new Proxy(base, {
    get: (_target, key) => (typeof key === "string" && key in extras ? extras[key] : base[key]),
    set: (_target, key, value) => {
      extras[key] = value
      return true
    },
  })
  root.cmux = cmux

  // Timers backed by the host (QuickJS has none). One-shot host timers fire
  // no sooner than 50 ms.
  const timers = new Map()
  let nextTimer = 1
  root.setTimeout = (fn, ms, ...args) => {
    const id = nextTimer++
    const hostTimer = cmux.timer.after(Math.max(0, Number(ms) || 0), () => {
      timers.delete(id)
      if (typeof fn === "function") fn(...args)
    })
    timers.set(id, hostTimer)
    return id
  }
  root.clearTimeout = (id) => {
    const hostTimer = timers.get(id)
    if (hostTimer === undefined) return
    timers.delete(id)
    cmux.timer.clear(hostTimer)
  }

  /** Resolves after `ms` milliseconds. */
  cmux.sleep = (ms) => new Promise((resolve) => root.setTimeout(resolve, ms))

  /**
   * Resolves when `predicate` holds, checked now and after every event on
   * `stream` (for example `resource.changed`). Without a predicate the first
   * event resolves it. `options.timeoutMs` rejects with `script.timeout`.
   * The result is the predicate's value when it is not `true`, else the event.
   */
  cmux.wait = (stream, predicate, options) => {
    if (predicate !== undefined && typeof predicate !== "function" && options === undefined) {
      options = predicate
      predicate = undefined
    }
    const timeoutMs = options && options.timeoutMs
    return new Promise((resolve, reject) => {
      let done = false
      let timer
      let off
      const finish = (settle, value) => {
        if (done) return
        done = true
        if (off) off()
        if (timer !== undefined) root.clearTimeout(timer)
        settle(value)
      }
      const check = (event) => {
        if (done) return
        if (!predicate) return finish(resolve, event)
        Promise.resolve()
          .then(() => predicate(event))
          .then(
            (held) => {
              if (held) finish(resolve, held === true ? event : held)
            },
            (error) => finish(reject, error)
          )
      }
      off = cmux.events.on(String(stream), check)
      if (timeoutMs !== undefined) {
        timer = root.setTimeout(() => finish(reject, new CmuxError("script.timeout", `nothing matched on ${stream} within ${timeoutMs} ms`)), timeoutMs)
      }
      if (predicate) check(undefined)
    })
  }

  cmux.args = {}

  const session = replHost.createReplSession({ host: { now: () => Date.now() }, globals: [{ console: root.console }] })

  // Results leave the VM as JSON; anything else becomes its string form.
  const plain = (value) => {
    if (value === undefined) return null
    try {
      const text = JSON.stringify(value)
      return text === undefined ? null : JSON.parse(text)
    } catch (e) {
      return String(value)
    }
  }

  root.__cmuxAppExports = {
    eval: async (request) => {
      const args = request && request.args
      cmux.args = args && typeof args === "object" && !Array.isArray(args) ? args : {}
      const result = await session.evaluate(String((request && request.code) || ""))
      if (!result.ok) {
        if (result.exception instanceof CmuxError) throw result.exception
        throw new CmuxError("script.error", String(result.error))
      }
      return plain(result.value)
    }
  }
})(globalThis)
