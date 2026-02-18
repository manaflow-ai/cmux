import type { TerminalAdapter, TerminalConfig } from "./terminal-adapter"
import { createTerminalAdapter, getRendererType } from "./terminal-adapter"

interface TerminalEntry {
  adapter: TerminalAdapter
  ws: WebSocket | null
  containerEl: HTMLDivElement
  shellAttached: boolean
}

type TitleChangeHandler = (tabId: string, title: string) => void

// --- Fake bash ---

interface ShellState {
  cwd: string
  env: Record<string, string>
  line: string
  history: string[]
  historyIdx: number
  cursorPos: number
  // Foreground process: captures all input, Ctrl+C kills it
  fg: { onData: (data: string) => void; kill: () => void } | null
}

const HOSTNAME = "cmux"
const USER = "user"

function prompt(s: ShellState): string {
  const dir = s.cwd === `/home/${USER}` ? "~" : s.cwd
  return `\x1b[1;32m${USER}@${HOSTNAME}\x1b[0m:\x1b[1;34m${dir}\x1b[0m$ `
}

function expandVars(s: string, env: Record<string, string>): string {
  return s.replace(/\$(\w+)/g, (_, k) => env[k] ?? "")
}

function attachFakeShell(adapter: TerminalAdapter): void {
  const state: ShellState = {
    cwd: `/home/${USER}`,
    env: { HOME: `/home/${USER}`, USER, SHELL: "/bin/bash", TERM: "xterm-256color", PATH: "/usr/local/bin:/usr/bin:/bin" },
    line: "",
    history: [],
    historyIdx: -1,
    cursorPos: 0,
    fg: null,
  }

  // Set title via OSC
  adapter.write(`\x1b]0;bash — ${HOSTNAME}\x07`)
  adapter.write(prompt(state))

  const eraseLine = () => {
    if (state.line.length > 0) {
      adapter.write(`\x1b[${state.line.length}D\x1b[K`)
    }
  }

  const redrawLine = () => {
    adapter.write(state.line)
    const diff = state.line.length - state.cursorPos
    if (diff > 0) adapter.write(`\x1b[${diff}D`)
  }

  const showPrompt = () => {
    adapter.write(prompt(state))
  }

  // --- Foreground process helpers ---

  /** Run a foreground process that reads lines from stdin */
  const fgReadLines = (onLine: (line: string) => void, onExit: () => void) => {
    let buf = ""
    state.fg = {
      onData(data: string) {
        for (const ch of data) {
          const code = ch.charCodeAt(0)
          if (code === 4) { // Ctrl+D = EOF
            if (buf.length === 0) {
              state.fg = null
              onExit()
              return
            }
          } else if (code === 13) { // Enter
            adapter.write("\r\n")
            onLine(buf)
            buf = ""
            continue
          } else if (code === 127) { // Backspace
            if (buf.length > 0) {
              buf = buf.slice(0, -1)
              adapter.write("\b \b")
            }
            continue
          } else if (code >= 32) {
            buf += ch
            adapter.write(ch)
            continue
          }
        }
      },
      kill() {
        state.fg = null
        onExit()
      },
    }
  }

  /** Run a foreground process that just blocks for `ms` then exits */
  const fgSleep = (ms: number) => {
    const timer = setTimeout(() => {
      state.fg = null
      showPrompt()
    }, ms)
    state.fg = {
      onData() {},
      kill() {
        clearTimeout(timer)
        state.fg = null
      },
    }
  }

  // --- Command execution ---

  const KNOWN_BINS = [
    "echo", "pwd", "whoami", "hostname", "date", "uname", "ls", "cd",
    "export", "env", "clear", "help", "exit", "cat", "sleep", "touch",
    "mkdir", "rm", "cp", "mv", "grep", "wc", "head", "tail", "which",
    "true", "false", "seq", "yes", "printf", "test", "[",
  ]

  const executeCommand = (cmd: string) => {
    const expanded = expandVars(cmd.trim(), state.env)
    const parts = expanded.split(/\s+/)
    const bin = parts[0]
    const args = parts.slice(1)

    if (!bin) { showPrompt(); return }

    let output = ""

    switch (bin) {
      case "echo":
        output = args.join(" ")
        break

      case "printf":
        output = args.join(" ").replace(/\\n/g, "\n").replace(/\\t/g, "\t")
        break

      case "pwd":
        output = state.cwd
        break

      case "whoami":
        output = USER
        break

      case "hostname":
        output = HOSTNAME
        break

      case "date":
        output = new Date().toString()
        break

      case "uname":
        output = args.includes("-a")
          ? `FakeBash 1.0.0 ${HOSTNAME} wasm wasm64 GNU/Linux`
          : "FakeBash"
        break

      case "ls": {
        const entries = ["Documents", "Downloads", "Desktop", ".bashrc", ".profile"]
        if (args.includes("-l")) {
          const now = new Date().toLocaleDateString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })
          output = `total ${entries.length}\n` +
            entries.map((e) => {
              const isDir = !e.startsWith(".")
              return `${isDir ? "d" : "-"}rwxr-xr-x  1 ${USER}  staff  ${(Math.random() * 4096 | 0).toString().padStart(5)}  ${now}  ${e}`
            }).join("\n")
        } else if (args.includes("-a")) {
          output = [".  ..", ...entries].join("  ")
        } else {
          output = entries.filter((e) => !e.startsWith(".")).join("  ")
        }
        break
      }

      case "cd": {
        const target = args[0] ?? state.env.HOME
        if (target === "~" || target === state.env.HOME) {
          state.cwd = state.env.HOME
        } else if (target === "..") {
          const p = state.cwd.split("/").filter(Boolean)
          p.pop()
          state.cwd = "/" + p.join("/") || "/"
        } else if (target === "-") {
          // no OLDPWD tracking, just stay
        } else if (target.startsWith("/")) {
          state.cwd = target
        } else {
          state.cwd = state.cwd === "/" ? `/${target}` : `${state.cwd}/${target}`
        }
        adapter.write(`\x1b]0;bash — ${state.cwd}\x07`)
        break
      }

      case "export":
        for (const arg of args) {
          const eq = arg.indexOf("=")
          if (eq > 0) state.env[arg.slice(0, eq)] = arg.slice(eq + 1)
        }
        break

      case "env":
        output = Object.entries(state.env).map(([k, v]) => `${k}=${v}`).join("\n")
        break

      case "clear":
        adapter.write("\x1b[2J\x1b[H")
        showPrompt()
        return

      case "help":
        output = "Available commands: " + KNOWN_BINS.join(", ")
        break

      case "exit":
        output = "logout"
        break

      // --- New commands ---

      case "sleep": {
        const secs = parseFloat(args[0] ?? "0")
        if (isNaN(secs) || secs <= 0) { showPrompt(); return }
        fgSleep(secs * 1000)
        return // prompt shown after sleep completes
      }

      case "cat": {
        if (args.length > 0) {
          // Fake cat file — pretend files don't exist
          output = `cat: ${args[0]}: No such file or directory`
          break
        }
        // cat with no args = read stdin, echo lines, Ctrl+D to exit
        fgReadLines(
          (line) => { adapter.write(line + "\r\n") },
          () => { showPrompt() },
        )
        return
      }

      case "touch":
      case "mkdir":
        // Silently succeed (fake fs)
        break

      case "rm":
      case "cp":
      case "mv":
        if (args.length === 0) {
          output = `${bin}: missing operand`
        }
        // Otherwise silently succeed
        break

      case "grep":
        if (args.length === 0) {
          output = "Usage: grep PATTERN [FILE]..."
        } else if (args.length === 1) {
          // grep with no file = read stdin
          fgReadLines(
            (line) => {
              if (line.includes(args[0])) {
                const highlighted = line.replace(args[0], `\x1b[1;31m${args[0]}\x1b[0m`)
                adapter.write(highlighted + "\r\n")
              }
            },
            () => { showPrompt() },
          )
          return
        } else {
          output = `grep: ${args[1]}: No such file or directory`
        }
        break

      case "wc": {
        if (args.length > 0 && !args[0].startsWith("-")) {
          output = `wc: ${args[0]}: No such file or directory`
          break
        }
        // wc reading stdin
        let lines = 0, words = 0, chars = 0
        fgReadLines(
          (line) => {
            lines++
            words += line.split(/\s+/).filter(Boolean).length
            chars += line.length + 1
          },
          () => {
            adapter.write(`      ${lines}       ${words}      ${chars}\r\n`)
            showPrompt()
          },
        )
        return
      }

      case "head":
      case "tail":
        if (args.length > 0 && !args[0].startsWith("-")) {
          output = `${bin}: ${args[0]}: No such file or directory`
        } else {
          // Read stdin, collect lines, show head/tail on Ctrl+D
          const collected: string[] = []
          const n = parseInt(args.find((a) => a.startsWith("-n"))?.slice(2) || args[1] || "10", 10) || 10
          fgReadLines(
            (line) => { collected.push(line) },
            () => {
              const slice = bin === "head" ? collected.slice(0, n) : collected.slice(-n)
              for (const l of slice) adapter.write(l + "\r\n")
              showPrompt()
            },
          )
          return
        }
        break

      case "which":
        if (args.length === 0) break
        if (KNOWN_BINS.includes(args[0])) {
          output = `/usr/bin/${args[0]}`
        } else {
          output = `${args[0]} not found`
        }
        break

      case "true":
        break

      case "false":
        break

      case "seq": {
        const start = args.length >= 2 ? parseInt(args[0], 10) : 1
        const end = parseInt(args[args.length - 1] ?? "1", 10)
        if (!isNaN(start) && !isNaN(end)) {
          const lines: string[] = []
          const step = start <= end ? 1 : -1
          for (let i = start; step > 0 ? i <= end : i >= end; i += step) {
            lines.push(String(i))
            if (lines.length > 1000) break
          }
          output = lines.join("\n")
        }
        break
      }

      case "yes": {
        const msg = args.length > 0 ? args.join(" ") : "y"
        let count = 0
        const maxLines = 50
        const iv = setInterval(() => {
          adapter.write(msg + "\r\n")
          count++
          if (count >= maxLines) {
            clearInterval(iv)
            state.fg = null
            showPrompt()
          }
        }, 30)
        state.fg = {
          onData() {},
          kill() {
            clearInterval(iv)
            state.fg = null
          },
        }
        return
      }

      case "test":
      case "[":
        // Silently succeed
        break

      default:
        output = `bash: ${bin}: command not found`
    }

    if (output) adapter.write(output + "\r\n")
    showPrompt()
  }

  // --- Input handler ---

  adapter.onData((data: string) => {
    // If a foreground process is running, route input to it
    if (state.fg) {
      for (const ch of data) {
        if (ch.charCodeAt(0) === 3) { // Ctrl+C
          adapter.write("^C\r\n")
          state.fg.kill()
          showPrompt()
          return
        }
        if (ch.charCodeAt(0) === 4) { // Ctrl+D
          state.fg.onData(ch)
          return
        }
      }
      state.fg.onData(data)
      return
    }

    // Normal line-editing mode
    for (let i = 0; i < data.length; i++) {
      const ch = data[i]
      const code = ch.charCodeAt(0)

      // Enter
      if (code === 13) {
        adapter.write("\r\n")
        const cmd = state.line
        if (cmd.trim()) state.history.push(cmd)
        state.historyIdx = -1
        state.line = ""
        state.cursorPos = 0
        executeCommand(cmd)
        continue
      }

      // Backspace
      if (code === 127) {
        if (state.cursorPos > 0) {
          state.line = state.line.slice(0, state.cursorPos - 1) + state.line.slice(state.cursorPos)
          state.cursorPos--
          adapter.write("\b" + state.line.slice(state.cursorPos) + " ")
          const back = state.line.length - state.cursorPos + 1
          if (back > 0) adapter.write(`\x1b[${back}D`)
        }
        continue
      }

      // Escape sequences
      if (ch === "\x1b" && data[i + 1] === "[") {
        const seq = data[i + 2]
        if (seq === "A") { // Up
          i += 2
          if (state.history.length > 0) {
            if (state.historyIdx === -1) state.historyIdx = state.history.length
            if (state.historyIdx > 0) {
              state.historyIdx--
              eraseLine()
              state.line = state.history[state.historyIdx]
              state.cursorPos = state.line.length
              redrawLine()
            }
          }
          continue
        }
        if (seq === "B") { // Down
          i += 2
          if (state.historyIdx !== -1) {
            eraseLine()
            if (state.historyIdx < state.history.length - 1) {
              state.historyIdx++
              state.line = state.history[state.historyIdx]
            } else {
              state.historyIdx = -1
              state.line = ""
            }
            state.cursorPos = state.line.length
            redrawLine()
          }
          continue
        }
        if (seq === "C") { // Right
          i += 2
          if (state.cursorPos < state.line.length) {
            state.cursorPos++
            adapter.write("\x1b[C")
          }
          continue
        }
        if (seq === "D") { // Left
          i += 2
          if (state.cursorPos > 0) {
            state.cursorPos--
            adapter.write("\x1b[D")
          }
          continue
        }
        i += 2
        continue
      }

      // Ctrl+C
      if (code === 3) {
        adapter.write("^C\r\n")
        state.line = ""
        state.cursorPos = 0
        state.historyIdx = -1
        showPrompt()
        continue
      }

      // Ctrl+D on empty line
      if (code === 4 && state.line.length === 0) {
        adapter.write("exit\r\n")
        continue
      }

      // Ctrl+L
      if (code === 12) {
        adapter.write("\x1b[2J\x1b[H")
        showPrompt()
        redrawLine()
        continue
      }

      // Ctrl+A
      if (code === 1) {
        if (state.cursorPos > 0) {
          adapter.write(`\x1b[${state.cursorPos}D`)
          state.cursorPos = 0
        }
        continue
      }

      // Ctrl+E
      if (code === 5) {
        const diff = state.line.length - state.cursorPos
        if (diff > 0) {
          adapter.write(`\x1b[${diff}C`)
          state.cursorPos = state.line.length
        }
        continue
      }

      // Ctrl+U — kill line
      if (code === 21) {
        if (state.cursorPos > 0) {
          const killed = state.line.slice(0, state.cursorPos)
          state.line = state.line.slice(state.cursorPos)
          adapter.write(`\x1b[${killed.length}D`)
          adapter.write(state.line + " ".repeat(killed.length))
          adapter.write(`\x1b[${state.line.length + killed.length}D`)
          if (state.line.length > 0) adapter.write(`\x1b[${state.line.length}C`)
          state.cursorPos = 0
          adapter.write(`\x1b[${state.line.length}D`)
        }
        continue
      }

      // Ctrl+K — kill to end
      if (code === 11) {
        const rest = state.line.length - state.cursorPos
        if (rest > 0) {
          state.line = state.line.slice(0, state.cursorPos)
          adapter.write("\x1b[K")
        }
        continue
      }

      // Printable
      if (code >= 32) {
        state.line = state.line.slice(0, state.cursorPos) + ch + state.line.slice(state.cursorPos)
        state.cursorPos++
        adapter.write(ch + state.line.slice(state.cursorPos))
        const back = state.line.length - state.cursorPos
        if (back > 0) adapter.write(`\x1b[${back}D`)
      }
    }
  })
}

// --- Multiplexed connection (mode=mux) ---

class CmuxdConnection {
  private ws: WebSocket | null = null
  private sessionCallbacks = new Map<number, (data: Uint8Array) => void>()
  private pendingCreates: Array<(sessionId: number) => void> = []
  private readyResolvers: Array<() => void> = []
  private _ready = false
  private _clientId: number | null = null

  // Multiplayer event handlers
  private _onClientJoined: Array<(clientId: number) => void> = []
  private _onClientLeft: Array<(clientId: number) => void> = []
  private _onDriverChanged: Array<(sessionId: number, driverId: number | null, mode?: string) => void> = []
  private _onSessionResized: Array<(sessionId: number, cols: number, rows: number) => void> = []
  // Terminal config from cmuxd (parsed from Ghostty config)
  private _terminalConfig: TerminalConfig | null = null
  // All text messages received (for e2e test inspection)
  _messages: Array<Record<string, unknown>> = []

  connect(url: string): Promise<void> {
    return new Promise((resolve, reject) => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        resolve()
        return
      }
      const ws = new WebSocket(url)
      ws.binaryType = "arraybuffer"
      this.ws = ws

      ws.onopen = () => {
        // Wait for workspace_snapshot before resolving
      }

      ws.onmessage = (e) => {
        if (typeof e.data === "string") {
          const msg = JSON.parse(e.data)
          this._messages.push(msg)
          if (msg.type === "workspace_snapshot" || msg.type === "workspace_update") {
            if (msg.clientId != null) this._clientId = msg.clientId
            if (msg.terminalConfig) this._terminalConfig = msg.terminalConfig as TerminalConfig
            if (!this._ready) {
              this._ready = true
              resolve()
              for (const r of this.readyResolvers) r()
              this.readyResolvers = []
            }
          } else if (msg.type === "session_created") {
            const cb = this.pendingCreates.shift()
            cb?.(msg.sessionId)
          } else if (msg.type === "client_joined") {
            for (const h of this._onClientJoined) h(msg.clientId)
          } else if (msg.type === "client_left") {
            for (const h of this._onClientLeft) h(msg.clientId)
          } else if (msg.type === "driver_changed") {
            for (const h of this._onDriverChanged) h(msg.sessionId, msg.driverId, msg.mode)
          } else if (msg.type === "session_resized") {
            for (const h of this._onSessionResized) h(msg.sessionId, msg.cols, msg.rows)
          }
        } else {
          // Binary: [4-byte session-id LE][data]
          const buf = new Uint8Array(e.data as ArrayBuffer)
          if (buf.length < 4) return
          const sid = buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24)
          const data = buf.subarray(4)
          this.sessionCallbacks.get(sid)?.(data)
        }
      }

      ws.onerror = () => {
        this.ws = null
        reject(new Error("cmuxd connection failed"))
      }

      ws.onclose = () => {
        this.ws = null
        this._ready = false
      }
    })
  }

  get ready() { return this._ready }
  get clientId() { return this._clientId }

  waitReady(): Promise<void> {
    if (this._ready) return Promise.resolve()
    return new Promise((r) => this.readyResolvers.push(r))
  }

  getTerminalConfig(): TerminalConfig | null {
    return this._terminalConfig
  }

  createSession(cols: number, rows: number): Promise<number> {
    return new Promise((resolve) => {
      this.pendingCreates.push(resolve)
      this.send(JSON.stringify({ type: "create_session", cols, rows }))
    })
  }

  destroySession(sessionId: number) {
    this.send(JSON.stringify({ type: "destroy_session", sessionId }))
    this.sessionCallbacks.delete(sessionId)
  }

  resizeSession(sessionId: number, cols: number, rows: number) {
    this.send(JSON.stringify({ type: "resize", sessionId, cols, rows }))
  }

  attachSession(sessionId: number, cols: number, rows: number) {
    this.send(JSON.stringify({ type: "attach_session", sessionId, cols, rows }))
  }

  detachSession(sessionId: number) {
    this.send(JSON.stringify({ type: "detach_session", sessionId }))
    this.sessionCallbacks.delete(sessionId)
  }

  setSessionMode(sessionId: number, mode: "shared" | "single_driver") {
    this.send(JSON.stringify({ type: "set_session_mode", sessionId, mode }))
  }

  requestDriver(sessionId: number) {
    this.send(JSON.stringify({ type: "request_driver", sessionId }))
  }

  releaseDriver(sessionId: number) {
    this.send(JSON.stringify({ type: "release_driver", sessionId }))
  }

  sendInput(sessionId: number, data: string) {
    const encoder = new TextEncoder()
    const encoded = encoder.encode(data)
    const buf = new Uint8Array(4 + encoded.length)
    buf[0] = sessionId & 0xFF
    buf[1] = (sessionId >> 8) & 0xFF
    buf[2] = (sessionId >> 16) & 0xFF
    buf[3] = (sessionId >> 24) & 0xFF
    buf.set(encoded, 4)
    this.ws?.send(buf)
  }

  onSessionData(sessionId: number, callback: (data: Uint8Array) => void) {
    this.sessionCallbacks.set(sessionId, callback)
  }

  onClientJoined(handler: (clientId: number) => void) { this._onClientJoined.push(handler) }
  onClientLeft(handler: (clientId: number) => void) { this._onClientLeft.push(handler) }
  onDriverChanged(handler: (sessionId: number, driverId: number | null, mode?: string) => void) { this._onDriverChanged.push(handler) }
  onSessionResized(handler: (sessionId: number, cols: number, rows: number) => void) { this._onSessionResized.push(handler) }

  close() {
    this.ws?.close()
    this.ws = null
  }

  private send(data: string | ArrayBuffer) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data)
    }
  }
}

// --- Registry ---

const PTY_WS_URL = "ws://localhost:3778/ws"

class SurfaceRegistry {
  private terminals = new Map<string, TerminalEntry>()
  private titleChangeHandler: TitleChangeHandler | null = null
  private muxConnection: CmuxdConnection | null = null
  private tabSessionMap = new Map<string, number>() // tabId -> sessionId

  /** Pre-connect the mux WebSocket to fetch terminalConfig (renderer, theme, etc.)
   *  before creating the first adapter. Only connects in mux mode. */
  private async ensureMuxConfig(): Promise<void> {
    const params = typeof window !== "undefined" ? window.location.search : ""
    if (!params.includes("mode=mux")) return
    if (this.muxConnection?.ready) return

    if (!this.muxConnection) {
      this.muxConnection = new CmuxdConnection()
    }
    // Connect with default dimensions — will be resized once terminal is created
    await this.muxConnection.connect(`${PTY_WS_URL}?mode=mux&cols=80&rows=24`)
  }

  async create(tabId: string): Promise<TerminalEntry> {
    const existing = this.terminals.get(tabId)
    if (existing) return existing

    // Pre-connect mux to get config (renderer type, theme, etc.) before creating adapter
    try { await this.ensureMuxConfig() } catch { /* non-mux mode or connection failed */ }

    const cfg = this.muxConnection?.getTerminalConfig()
    const rendererType = getRendererType(cfg?.renderer)

    const adapter = await createTerminalAdapter(rendererType)
    await adapter.init()

    adapter.create({
      cursorBlink: cfg?.cursorBlink ?? false,
      cursorStyle: cfg?.cursorStyle,
      fontSize: cfg?.fontSize ?? 12,
      fontFamily: cfg?.fontFamily ? `${cfg.fontFamily}, Monaco, monospace` : "Menlo, Monaco, monospace",
      theme: cfg?.theme ?? {
        background: "#171717",
        foreground: "#ededed",
      },
      scrollback: cfg?.scrollback ?? 10000,
    })

    const containerEl = document.createElement("div")
    containerEl.style.width = "100%"
    containerEl.style.height = "100%"

    adapter.open(containerEl)

    adapter.onTitleChange((title: string) => {
      this.titleChangeHandler?.(tabId, title)
    })

    const entry: TerminalEntry = { adapter, ws: null, containerEl, shellAttached: false }
    this.terminals.set(tabId, entry)
    return entry
  }

  get(tabId: string): TerminalEntry | undefined {
    return this.terminals.get(tabId)
  }

  /** Attach the fake in-browser shell */
  private attachShell(tabId: string): void {
    const entry = this.terminals.get(tabId)
    if (!entry || entry.shellAttached) return
    entry.shellAttached = true
    attachFakeShell(entry.adapter)
  }

  /** Connect to the PTY WebSocket server. Resolves on open, rejects on error. */
  private connectWebSocket(tabId: string, wsUrl: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const entry = this.terminals.get(tabId)
      if (!entry) { reject(new Error("no entry")); return }
      if (entry.ws) { resolve(); return }

      const { cols, rows } = entry.adapter.proposeDimensions() ?? { cols: 80, rows: 24 }
      const url = `${wsUrl}?cols=${cols}&rows=${rows}`
      const ws = new WebSocket(url)
      ws.binaryType = "arraybuffer"
      entry.ws = ws // store immediately so destroy() can close it

      ws.onopen = () => {
        ws.onmessage = (e) => {
          const data = typeof e.data === "string" ? e.data : new Uint8Array(e.data as ArrayBuffer)
          entry.adapter.write(data)
        }

        ws.onclose = () => {
          entry.ws = null
        }

        entry.adapter.onData((data: string) => {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(data)
          }
        })

        entry.adapter.onResize(({ cols, rows }: { cols: number; rows: number }) => {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: "resize", cols, rows }))
          }
        })

        // Re-fit now that connection is live — ensures PTY gets actual dimensions
        entry.adapter.fit()

        resolve()
      }

      ws.onerror = () => {
        entry.ws = null
        ws.close()
        reject(new Error("PTY WebSocket connection failed"))
      }
    })
  }

  /** Connect via multiplexed cmuxd protocol (single shared WS, session-per-tab). */
  private async connectMux(tabId: string): Promise<void> {
    const entry = this.terminals.get(tabId)
    if (!entry) throw new Error("no entry")

    // Lazily connect the shared mux WebSocket
    if (!this.muxConnection) {
      this.muxConnection = new CmuxdConnection()
    }
    if (!this.muxConnection.ready) {
      const { cols, rows } = entry.adapter.proposeDimensions() ?? { cols: 80, rows: 24 }
      await this.muxConnection.connect(`${PTY_WS_URL}?mode=mux&cols=${cols}&rows=${rows}`)
    }

    // Create a session for this tab
    const { cols, rows } = entry.adapter.proposeDimensions() ?? { cols: 80, rows: 24 }
    const sessionId = await this.muxConnection.createSession(cols, rows)
    this.tabSessionMap.set(tabId, sessionId)

    // Wire PTY output → terminal
    this.muxConnection.onSessionData(sessionId, (data: Uint8Array) => {
      entry.adapter.write(data)
    })

    // Wire terminal input → PTY
    entry.adapter.onData((data: string) => {
      this.muxConnection?.sendInput(sessionId, data)
    })

    // Wire resize → PTY
    entry.adapter.onResize(({ cols, rows }: { cols: number; rows: number }) => {
      this.muxConnection?.resizeSession(sessionId, cols, rows)
    })

    // Re-fit now that connection is live — ensures PTY gets actual dimensions
    entry.adapter.fit()
  }

  /** Try PTY WebSocket, fall back to fake in-browser shell.
   *  URL param ?shell=local forces fake shell (useful for tests that don't need PTY).
   *  URL param ?mode=mux uses multiplexed cmuxd protocol. */
  async connect(tabId: string): Promise<void> {
    const entry = this.terminals.get(tabId)
    if (!entry || entry.ws || entry.shellAttached) return
    // Skip if already connected via mux
    if (this.tabSessionMap.has(tabId)) return

    const params = typeof window !== "undefined" ? window.location.search : ""
    const forceLocal = params.includes("shell=local")
    const useMux = params.includes("mode=mux")

    if (!forceLocal) {
      if (useMux) {
        try {
          await this.connectMux(tabId)
          return
        } catch { /* fall through to legacy */ }
      }
      try {
        await this.connectWebSocket(tabId, PTY_WS_URL)
        return
      } catch { /* fall through to fake shell */ }
    }
    this.attachShell(tabId)
  }

  setFocused(tabId: string, focused: boolean): void {
    const entry = this.terminals.get(tabId)
    if (!entry) return
    entry.adapter.setFocused(focused)
  }

  clearTerminal(tabId: string): void {
    const entry = this.terminals.get(tabId)
    if (!entry) return
    // Clear scrollback + screen client-side
    entry.adapter.write("\x1b[3J\x1b[2J\x1b[H")
    // Send Ctrl+L to PTY so the shell redraws its prompt
    const sessionId = this.tabSessionMap.get(tabId)
    if (sessionId !== undefined && this.muxConnection) {
      this.muxConnection.sendInput(sessionId, "\x0c")
    } else if (entry.ws?.readyState === WebSocket.OPEN) {
      entry.ws.send("\x0c")
    }
  }

  destroy(tabId: string): void {
    const entry = this.terminals.get(tabId)
    if (!entry) return

    // Clean up mux session if connected
    const sessionId = this.tabSessionMap.get(tabId)
    if (sessionId !== undefined && this.muxConnection) {
      this.muxConnection.destroySession(sessionId)
      this.tabSessionMap.delete(tabId)
    }

    if (entry.ws) {
      entry.ws.close()
      entry.ws = null
    }
    entry.adapter.dispose()
    entry.containerEl.remove()
    this.terminals.delete(tabId)
  }

  /** Get the mux session ID for a tab (for test/debug access). */
  getMuxSessionId(tabId: string): number | undefined {
    return this.tabSessionMap.get(tabId)
  }

  /** Get the mux connection (for test/debug access). */
  getMuxConnection(): CmuxdConnection | null {
    return this.muxConnection
  }

  /** Read the visible screen text for a terminal. */
  getScreenText(tabId: string): string {
    const entry = this.terminals.get(tabId)
    if (!entry) return ""
    return entry.adapter.getScreenText()
  }

  setTitleChangeHandler(handler: TitleChangeHandler): void {
    this.titleChangeHandler = handler
  }
}

export const surfaceRegistry = new SurfaceRegistry()

// Expose for e2e test access
if (typeof window !== "undefined") {
  ;(window as any).__surfaceRegistry = surfaceRegistry
}
