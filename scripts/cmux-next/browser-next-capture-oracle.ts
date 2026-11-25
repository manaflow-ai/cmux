// Passive evidence only: never sends a frame or installs a browser host bridge.
import { EventEmitter } from "node:events"

type Request = { method: string; target?: string; nonce?: boolean }
export class CaptureOracle extends EventEmitter {
  private sockets = new Map<number, { pending: Map<unknown, Request>; hello: boolean; attached: boolean; prompted: boolean; reply: string }>()
  helloCount = 0
  attachCount = 0
  promptSent = false
  replySeen = false
  completed = false
  constructor(readonly target: string, readonly nonce: string) { super() }

  observe(socket: number, direction: "sent" | "received", payload: string | Buffer): void {
    let message: any
    try { message = JSON.parse(String(payload)) } catch { return }
    if (!message || typeof message !== "object") return
    let state = this.sockets.get(socket)
    if (!state) {
      state = { pending: new Map(), hello: false, attached: false, prompted: false, reply: "" }
      this.sockets.set(socket, state)
    }
    if (direction === "sent") {
      const method = message.method
      if (!["_acpmux/device_hello", "_acpmux/attach", "session/prompt"].includes(method)) return
      if (message.id === undefined || message.id === null) return
      const target = message.params?.sessionId
      const nonce = method === "session/prompt" && Array.isArray(message.params?.prompt) &&
        message.params.prompt.some((part: any) => part.type === "text" && typeof part.text === "string" && part.text.includes(this.nonce))
      state.pending.set(message.id, { method, target, nonce })
      if (method === "session/prompt" && state.attached && this.matches(target) && nonce) {
        this.promptSent = true
        state.prompted = true
      }
    } else if (message.method === undefined) {
      const request = state.pending.get(message.id)
      if (!request) return
      state.pending.delete(message.id)
      if (message.error || !message.result) return
      if (request.method === "_acpmux/device_hello" && message.result.auth === "webDevice") {
        state.hello = true
        this.helloCount++
      }
      if (request.method === "_acpmux/attach" && state.hello && request.target === this.target) {
        state.attached = true
        this.attachCount++
      }
      if (request.method === "session/prompt" && state.attached && this.matches(request.target) && request.nonce && message.result.stopReason === "end_turn") this.completed = true
    } else if (state.attached && state.prompted) {
      // The pane's eventStream attach wraps ACP messages in daemon event records.
      const event = message.method === "_acpmux/event" ? message.params : undefined
      if (event && (event.dir !== "in" || !this.matches(event.sessionId))) return
      const updateMessage = event ? event.msg : message
      if (updateMessage?.method !== "session/update" || (!event && !this.matches(updateMessage.params?.sessionId))) return
      const update = updateMessage.params?.update
      if (update?.sessionUpdate !== "agent_message_chunk") return
      const content = update.content
      const text = typeof content?.text === "string" ? content.text : Array.isArray(content) ? content.map((part: any) => typeof part?.text === "string" ? part.text : "").join("") : ""
      state.reply = (state.reply + text).slice(-4096)
      this.replySeen ||= state.reply.includes(this.nonce)
    }
    this.emit("change")
  }

  private matches(target: unknown): boolean {
    return target === this.target || target === this.target.split("/").at(-1)
  }

  wait(predicate: () => boolean, timeoutMs: number, stage: string): Promise<void> {
    if (predicate()) return Promise.resolve()
    return new Promise((resolve, reject) => {
      const finish = (error?: Error) => {
        clearTimeout(timer)
        this.removeListener("change", changed)
        error ? reject(error) : resolve()
      }
      const changed = () => { if (predicate()) finish() }
      const timer = setTimeout(() => finish(new Error(stage)), timeoutMs)
      this.on("change", changed)
    })
  }

  summary() {
    return { helloCount: this.helloCount, attachCount: this.attachCount, promptSent: this.promptSent, replySeen: this.replySeen, completed: this.completed }
  }
}
