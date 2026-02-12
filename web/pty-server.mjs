import { createServer } from "http"
import { WebSocketServer } from "ws"
import pty from "@lydell/node-pty"
import { platform, env } from "process"

const PORT = parseInt(env.PTY_PORT || "3778", 10)
const SHELL = env.SHELL || (platform === "win32" ? "powershell.exe" : "/bin/zsh")

const server = createServer((_req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" })
  res.end("cmux PTY server\n")
})

const wss = new WebSocketServer({ server, path: "/ws" })

wss.on("connection", (ws, req) => {
  const url = new URL(req.url, `http://localhost:${PORT}`)
  const cols = parseInt(url.searchParams.get("cols") || "80", 10)
  const rows = parseInt(url.searchParams.get("rows") || "24", 10)

  const proc = pty.spawn(SHELL, [], {
    name: "xterm-256color",
    cols,
    rows,
    cwd: env.PTY_CWD || process.cwd(),
    env: { ...env },
  })

  proc.onData((data) => {
    if (ws.readyState === ws.OPEN) {
      ws.send(data)
    }
  })

  proc.onExit(() => {
    if (ws.readyState === ws.OPEN) {
      ws.close()
    }
  })

  ws.on("message", (msg) => {
    const str = msg.toString()
    // Check for resize JSON messages
    if (str.startsWith("{")) {
      try {
        const parsed = JSON.parse(str)
        if (parsed.type === "resize" && parsed.cols && parsed.rows) {
          proc.resize(parsed.cols, parsed.rows)
          return
        }
      } catch {
        // Not JSON, fall through to write as input
      }
    }
    proc.write(str)
  })

  ws.on("close", () => {
    proc.kill()
  })
})

server.listen(PORT, () => {
  console.log(`PTY server listening on :${PORT}`)
})
