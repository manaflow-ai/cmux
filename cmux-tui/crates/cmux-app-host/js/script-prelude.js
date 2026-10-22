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

  // An event matches a filter object when every field of the filter equals
  // the event's field of that name (`{ terminal: "term_..." }`).
  const matches = (filter, event) => {
    if (!filter) return true
    for (const key of Object.keys(filter)) {
      if (!event || event[key] !== filter[key]) return false
    }
    return true
  }
  const isFilter = (value) => value !== null && typeof value === "object" && !Array.isArray(value)
  const describe = (error) => (error && error.message ? error.message : String(error))
  const subscribe = base.events.on

  // Handlers registered with `cmux.on`. A one-shot run lasts while there are
  // some, until `cmux.stop(value)`; REPL cells never wait for them.
  const handlers = new Set()
  // The waiting run's resolver, and `{ value }` once `cmux.stop` ran in this cell.
  let held = null
  let stopped = null
  const release = () => {
    if (!held) return
    const settle = held
    held = null
    settle()
  }

  /**
   * Calls `fn(event)` for each event on `stream` whose fields match `filter`
   * (optional object). Returns a function that removes the handler. An error
   * a handler throws is logged and the handler stays.
   */
  cmux.on = (stream, filter, fn) => {
    if (typeof filter === "function" && fn === undefined) {
      fn = filter
      filter = undefined
    }
    if (typeof fn !== "function") throw new CmuxError("validation.invalid", "cmux.on needs a handler function")
    if (filter !== undefined && !isFilter(filter)) throw new CmuxError("validation.invalid", "the cmux.on filter must be an object")
    const name = String(stream)
    const report = (error) => console.error(`${name} handler: ${describe(error)}`)
    const entry = {}
    const off = subscribe(name, (event) => {
      if (!handlers.has(entry) || !matches(filter, event)) return
      try {
        const result = fn(event)
        if (result && typeof result.then === "function") result.then(undefined, report)
      } catch (error) {
        report(error)
      }
    })
    entry.off = () => {
      if (!handlers.delete(entry)) return
      off()
      if (handlers.size === 0) release()
    }
    handlers.add(entry)
    return entry.off
  }

  /** Ends a one-shot run that waits for its handlers; `value` is its result. */
  cmux.stop = (value) => {
    stopped = { value }
    for (const entry of Array.from(handlers)) entry.off()
    release()
  }

  /**
   * An async iterator over the events on `stream` that match `filter`,
   * buffered from the moment it is created. `break` ends it.
   */
  cmux.stream = (stream, filter) => {
    if (filter !== undefined && !isFilter(filter)) throw new CmuxError("validation.invalid", "the cmux.stream filter must be an object")
    const queue = []
    let wake = null
    let done = false
    const off = subscribe(String(stream), (event) => {
      if (done || !matches(filter, event)) return
      queue.push(event)
      if (wake) {
        const resume = wake
        wake = null
        resume()
      }
    })
    const finish = () => {
      done = true
      off()
      if (wake) {
        const resume = wake
        wake = null
        resume()
      }
      return Promise.resolve({ value: undefined, done: true })
    }
    return {
      [Symbol.asyncIterator]() {
        return this
      },
      async next() {
        while (!done && queue.length === 0) await new Promise((resolve) => (wake = resolve))
        if (queue.length > 0) return { value: queue.shift(), done: false }
        return { value: undefined, done: true }
      },
      return: finish,
    }
  }

  /**
   * Resolves when `predicate` holds, checked now and after every event on
   * `stream` (for example `resource.changed`). Without a predicate the first
   * event resolves it. `options.timeoutMs` rejects with `script.timeout`.
   * The result is the predicate's value when it is not `true`, else the event.
   */
  cmux.wait = (stream, predicate, options) => {
    // `wait(stream, options)` when the object holds only `timeoutMs`.
    if (isFilter(predicate) && options === undefined && Object.keys(predicate).every((key) => key === "timeoutMs")) {
      options = predicate
      predicate = undefined
    }
    if (isFilter(predicate)) {
      const filter = predicate
      predicate = (event) => event !== undefined && matches(filter, event)
    } else if (predicate !== undefined && typeof predicate !== "function") {
      throw new CmuxError("validation.invalid", "the cmux.wait predicate must be a function or a filter object")
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
      off = subscribe(String(stream), check)
      if (timeoutMs !== undefined) {
        timer = root.setTimeout(() => finish(reject, new CmuxError("script.timeout", `nothing matched on ${stream} within ${timeoutMs} ms`)), timeoutMs)
      }
      if (predicate) check(undefined)
    })
  }

  // Config as code (scripting-runtime.md section 5): user actions, key
  // bindings and key modes. The daemon reads them with the `config` export
  // after it loads the config scripts, and runs an action with `action`.
  const invalid = (message) => new CmuxError("validation.invalid", message)
  const userActions = new Map()
  const keyBindings = []
  const keyModes = new Map()
  const keyRemovals = []
  let keyActions = 0
  const NAME = /^[a-z0-9][a-z0-9_.-]*$/
  const text = (value) => (typeof value === "string" && value.trim() ? value.trim() : null)
  const plainObject = (value, what) => {
    if (value === undefined || value === null) return {}
    if (!isFilter(value)) throw invalid(`${what} must be an object`)
    return plain(value)
  }

  const defineAction = (name, fields, run, palette) => {
    if (userActions.has(name)) throw invalid(`the action user.${name} is already defined`)
    userActions.set(name, { name, title: fields.title || name, description: fields.description || null, palette, run })
    return `user.${name}`
  }

  /**
   * Defines the user action `user.<name>`: `{ name, title?, description?, run(ctx, args) }`.
   * The palette, keys, `cmux script action` and scripts run it; `ctx.origin`
   * says who asked. Returns the action id.
   */
  cmux.action = (definition) => {
    if (!isFilter(definition)) throw invalid("cmux.action needs { name, run }")
    const name = definition.name
    if (typeof name !== "string" || !NAME.test(name) || name.startsWith("key.")) {
      throw invalid(`the action name ${JSON.stringify(name)} must be lowercase letters, digits, '.', '_' or '-', and not start with 'key.'`)
    }
    if (typeof definition.run !== "function") throw invalid(`the action ${name} needs a run function`)
    return defineAction(name, { title: text(definition.title), description: text(definition.description) }, definition.run, true)
  }

  cmux.keys = {
    /**
     * Binds `key` (keybindings.json syntax: strokes separated by spaces,
     * such as `cmd+k s`) to an action id or a function. Options: `args`
     * (the action's args), `when` (a when clause), `mode` (only while that
     * key mode is on).
     */
    bind: (key, target, options) => {
      const keyText = text(key)
      if (!keyText) throw invalid("cmux.keys.bind needs a key")
      const opts = plainObject(options, "the cmux.keys.bind options")
      const mode = opts.mode === undefined || opts.mode === null ? null : String(opts.mode)
      if (mode !== null && !keyModes.has(mode)) throw invalid(`the key mode ${mode} is not defined (cmux.keys.mode)`)
      let command
      if (typeof target === "function") {
        keyActions += 1
        command = defineAction(`key.${keyActions}`, { title: keyText }, target, false)
      } else if (text(target)) {
        command = text(target)
      } else {
        throw invalid("cmux.keys.bind needs an action id or a function")
      }
      keyBindings.push({ key: keyText, command, args: plainObject(opts.args, "args"), when: text(opts.when), mode })
    },
    /** Removes the default binding of `command` on `key` (every key when absent). */
    unbind: (command, key) => {
      const commandText = text(command)
      if (!commandText) throw invalid("cmux.keys.unbind needs an action id")
      keyRemovals.push({ command: commandText, key: text(key) })
    },
    /**
     * Defines key mode `name`: bindings with `{ mode: name }` work only
     * while it is on. An exclusive mode (the default) swallows other keys.
     */
    mode: (name, options) => {
      if (typeof name !== "string" || !NAME.test(name)) throw invalid(`the key mode name ${JSON.stringify(name)} is not valid`)
      if (keyModes.has(name)) throw invalid(`the key mode ${name} is already defined`)
      const opts = plainObject(options, "the cmux.keys.mode options")
      keyModes.set(name, { name, title: text(opts.title) || name, exclusive: opts.exclusive !== false })
    },
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
    // What the config scripts defined.
    config: () => ({
      actions: Array.from(userActions.values(), (a) => ({ id: `user.${a.name}`, name: a.name, title: a.title, description: a.description, palette: a.palette })),
      keys: keyBindings.map((b) => ({ ...b })),
      modes: Array.from(keyModes.values(), (m) => ({ ...m })),
      removals: keyRemovals.map((r) => ({ ...r })),
    }),
    // Runs user action `name` with `args` and `context` (`{ origin, ... }`).
    action: async (request) => {
      const name = String((request && request.name) || "")
      const action = userActions.get(name)
      if (!action) throw new CmuxError("action.not_found", `no user action ${name}`)
      const context = isFilter(request.context) ? request.context : {}
      const args = isFilter(request.args) ? request.args : {}
      try {
        return plain(await action.run({ ...context, origin: String(context.origin || "script") }, args))
      } catch (error) {
        if (error instanceof CmuxError) throw error
        throw new CmuxError("script.error", `user.${name}: ${describe(error)}`)
      }
    },
    eval: async (request) => {
      const args = request && request.args
      cmux.args = args && typeof args === "object" && !Array.isArray(args) ? args : {}
      stopped = null
      const result = await session.evaluate(String((request && request.code) || ""))
      if (!result.ok) {
        if (result.exception instanceof CmuxError) throw result.exception
        throw new CmuxError("script.error", String(result.error))
      }
      // A one-shot run lasts while its handlers do; `cmux.stop(value)` gives the result.
      if (request && request.hold === true) {
        if (handlers.size > 0 && !stopped) await new Promise((resolve) => (held = resolve))
        if (stopped) return plain(stopped.value)
      }
      return plain(result.value)
    }
  }
})(globalThis)
