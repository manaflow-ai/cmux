import { Terminal, FitAddon } from "ghostty-web"
import { ensureGhosttyInit } from "./ghostty-init"
import type { TerminalAdapter, TerminalConfig } from "./terminal-adapter"

// --- Mouse handler (ghostty-specific SGR mouse protocol) ---

class MouseHandler {
  private terminal: Terminal
  private canvas: HTMLCanvasElement | null = null
  private abortController = new AbortController()

  constructor(terminal: Terminal) {
    this.terminal = terminal
    this.canvas = terminal.element?.querySelector("canvas") ?? null
    if (this.canvas) this.attach()
  }

  private pixelToCell(x: number, y: number): { col: number; row: number } {
    const cw = this.terminal.renderer!.charWidth
    const ch = this.terminal.renderer!.charHeight
    return {
      col: Math.max(0, Math.min(Math.floor(x / cw), this.terminal.cols - 1)) + 1,
      row: Math.max(0, Math.min(Math.floor(y / ch), this.terminal.rows - 1)) + 1,
    }
  }

  private sendSGR(btn: number, col: number, row: number, press: boolean) {
    const seq = `\x1b[<${btn};${col};${row}${press ? "M" : "m"}`
    this.terminal.input(seq, true)
  }

  private attach() {
    const canvas = this.canvas!
    const signal = this.abortController.signal

    canvas.addEventListener("mousedown", (e: MouseEvent) => {
      if (!this.terminal.hasMouseTracking()) return
      e.preventDefault()
      const { col, row } = this.pixelToCell(e.offsetX, e.offsetY)
      this.sendSGR(e.button, col, row, true)
    }, { signal })

    canvas.addEventListener("mouseup", (e: MouseEvent) => {
      if (!this.terminal.hasMouseTracking()) return
      const { col, row } = this.pixelToCell(e.offsetX, e.offsetY)
      this.sendSGR(e.button, col, row, false)
    }, { signal })

    canvas.addEventListener("mousemove", (e: MouseEvent) => {
      if (!this.terminal.hasMouseTracking()) return
      if (e.buttons === 0) return
      if (!this.terminal.getMode(1002, false) && !this.terminal.getMode(1003, false)) return
      const { col, row } = this.pixelToCell(e.offsetX, e.offsetY)
      const btn = 32 + (e.buttons & 1 ? 0 : e.buttons & 2 ? 2 : e.buttons & 4 ? 1 : 0)
      this.sendSGR(btn, col, row, true)
    }, { signal })

    canvas.addEventListener("wheel", (e: WheelEvent) => {
      if (!this.terminal.hasMouseTracking()) return
      e.preventDefault()
      const { col, row } = this.pixelToCell(e.offsetX, e.offsetY)
      const btn = e.deltaY < 0 ? 64 : 65
      this.sendSGR(btn, col, row, true)
    }, { passive: false, capture: true, signal } as AddEventListenerOptions)

    canvas.addEventListener("contextmenu", (e: Event) => {
      if (this.terminal.hasMouseTracking()) e.preventDefault()
    }, { signal })
  }

  dispose() {
    this.abortController.abort()
  }
}

// --- Ghostty adapter ---

export class GhosttyAdapter implements TerminalAdapter {
  // Expose for e2e tests that need renderer access
  terminal: Terminal | null = null
  private fitAddon: FitAddon | null = null
  private mouseHandler: MouseHandler | null = null
  private _containerEl: HTMLDivElement | null = null

  async init(): Promise<void> {
    await ensureGhosttyInit()
  }

  create(config: TerminalConfig): void {
    this.terminal = new Terminal({
      cursorBlink: config.cursorBlink ?? false,
      cursorStyle: config.cursorStyle,
      fontSize: config.fontSize ?? 12,
      fontFamily: config.fontFamily ? `${config.fontFamily}, Monaco, monospace` : "Menlo, Monaco, monospace",
      theme: config.theme ?? {
        background: "#171717",
        foreground: "#ededed",
      },
      scrollback: config.scrollback ?? 10000,
    })

    this.fitAddon = new FitAddon()
    this.terminal.loadAddon(this.fitAddon)
  }

  open(container: HTMLDivElement): void {
    if (!this.terminal) throw new Error("GhosttyAdapter: call create() before open()")
    this._containerEl = container
    this.terminal.open(container)
    this.mouseHandler = new MouseHandler(this.terminal)
  }

  dispose(): void {
    this.mouseHandler?.dispose()
    this.fitAddon?.dispose()
    this.terminal?.dispose()
    this.mouseHandler = null
    this.fitAddon = null
    this.terminal = null
    this._containerEl = null
  }

  write(data: string | Uint8Array): void {
    this.terminal?.write(data)
  }

  onData(handler: (data: string) => void): { dispose: () => void } {
    return this.terminal!.onData(handler)
  }

  onResize(handler: (size: { cols: number; rows: number }) => void): { dispose: () => void } {
    return this.terminal!.onResize(handler)
  }

  onTitleChange(handler: (title: string) => void): { dispose: () => void } {
    return this.terminal!.onTitleChange(handler)
  }

  focus(): void {
    this.terminal?.focus()
  }

  blur(): void {
    this.terminal?.blur()
  }

  setFocused(focused: boolean): void {
    if (!this.terminal) return
    this.terminal.options.cursorBlink = focused

    // Unfocused: hollow outline cursor via monkey-patched renderCursor
    const renderer = this.terminal.renderer as any
    if (renderer) {
      if (!renderer._origRenderCursor) {
        renderer._origRenderCursor = renderer.renderCursor.bind(renderer)
      }
      if (focused) {
        renderer.renderCursor = renderer._origRenderCursor
      } else {
        renderer.renderCursor = (x: number, y: number) => {
          const px = x * renderer.metrics.width
          const py = y * renderer.metrics.height
          const ctx = renderer.ctx as CanvasRenderingContext2D
          ctx.strokeStyle = renderer.theme.cursor
          ctx.lineWidth = 1 * (renderer.devicePixelRatio || 1)
          ctx.strokeRect(px + 0.5, py + 0.5, renderer.metrics.width - 1, renderer.metrics.height - 1)
        }
      }
    }

    if (focused) {
      this.terminal.focus()
    } else {
      this.terminal.blur()
    }
  }

  fit(): void {
    this.fitAddon?.fit()
  }

  observeResize(): void {
    this.fitAddon?.observeResize()
  }

  proposeDimensions(): { cols: number; rows: number } | undefined {
    return this.fitAddon?.proposeDimensions() ?? undefined
  }

  getScreenText(): string {
    if (!this.terminal) return ""
    const buf = this.terminal.buffer.active
    const lines: string[] = []
    for (let y = 0; y < this.terminal.rows; y++) {
      const line = buf.getLine(buf.baseY + buf.viewportY + y)
      if (line) lines.push(line.translateToString(true))
    }
    return lines.join("\n")
  }

  input(data: string, wasUserInput: boolean): void {
    this.terminal?.input(data, wasUserInput)
  }

  get cols(): number {
    return this.terminal?.cols ?? 80
  }

  get rows(): number {
    return this.terminal?.rows ?? 24
  }

  get containerEl(): HTMLDivElement | null {
    return this._containerEl
  }
}
