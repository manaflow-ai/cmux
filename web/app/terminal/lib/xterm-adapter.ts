import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
// @ts-ignore — CSS import handled by bundler
import "@xterm/xterm/css/xterm.css"
import type { TerminalAdapter, TerminalConfig } from "./terminal-adapter"

export class XtermAdapter implements TerminalAdapter {
  private terminal: Terminal | null = null
  private fitAddon: FitAddon | null = null
  private resizeObserver: ResizeObserver | null = null
  private _containerEl: HTMLDivElement | null = null

  async init(): Promise<void> {
    // No WASM to load — CSS is imported at module level
  }

  create(config: TerminalConfig): void {
    // Map our theme format to xterm.js ITheme
    const theme = config.theme ? {
      foreground: config.theme.foreground,
      background: config.theme.background,
      cursor: config.theme.cursor,
      cursorAccent: config.theme.cursorAccent,
      selectionBackground: config.theme.selectionBackground,
      selectionForeground: config.theme.selectionForeground,
      black: config.theme.black,
      red: config.theme.red,
      green: config.theme.green,
      yellow: config.theme.yellow,
      blue: config.theme.blue,
      magenta: config.theme.magenta,
      cyan: config.theme.cyan,
      white: config.theme.white,
      brightBlack: config.theme.brightBlack,
      brightRed: config.theme.brightRed,
      brightGreen: config.theme.brightGreen,
      brightYellow: config.theme.brightYellow,
      brightBlue: config.theme.brightBlue,
      brightMagenta: config.theme.brightMagenta,
      brightCyan: config.theme.brightCyan,
      brightWhite: config.theme.brightWhite,
    } : {
      background: "#171717",
      foreground: "#ededed",
    }

    this.terminal = new Terminal({
      cursorBlink: config.cursorBlink ?? false,
      cursorStyle: config.cursorStyle,
      cursorInactiveStyle: "outline",
      fontSize: config.fontSize ?? 12,
      fontFamily: config.fontFamily ? `${config.fontFamily}, Monaco, monospace` : "Menlo, Monaco, monospace",
      scrollback: config.scrollback ?? 10000,
      allowProposedApi: true,
      theme,
    })
  }

  open(container: HTMLDivElement): void {
    if (!this.terminal) throw new Error("XtermAdapter: call create() before open()")
    this._containerEl = container
    this.terminal.open(container)
    this.loadAddons()
  }

  private async loadAddons(): Promise<void> {
    if (!this.terminal) return

    // FitAddon (required)
    this.fitAddon = new FitAddon()
    this.terminal.loadAddon(this.fitAddon)

    // WebGL renderer (best performance, graceful fallback)
    try {
      const { WebglAddon } = await import("@xterm/addon-webgl")
      this.terminal.loadAddon(new WebglAddon())
    } catch {
      // Canvas fallback — xterm.js uses canvas renderer by default
    }

    // Web links (clickable URLs)
    try {
      const { WebLinksAddon } = await import("@xterm/addon-web-links")
      this.terminal.loadAddon(new WebLinksAddon())
    } catch {}

    // Search
    try {
      const { SearchAddon } = await import("@xterm/addon-search")
      this.terminal.loadAddon(new SearchAddon())
    } catch {}

    // Unicode11 (correct character widths)
    try {
      const { Unicode11Addon } = await import("@xterm/addon-unicode11")
      const unicode11 = new Unicode11Addon()
      this.terminal.loadAddon(unicode11)
      this.terminal.unicode.activeVersion = "11"
    } catch {}

    // Inline images (SIXEL, iTerm)
    try {
      const { ImageAddon } = await import("@xterm/addon-image")
      this.terminal.loadAddon(new ImageAddon())
    } catch {}

    // OSC 52 clipboard
    try {
      const { ClipboardAddon } = await import("@xterm/addon-clipboard")
      this.terminal.loadAddon(new ClipboardAddon())
    } catch {}

    // Serialize (buffer serialization)
    try {
      const { SerializeAddon } = await import("@xterm/addon-serialize")
      this.terminal.loadAddon(new SerializeAddon())
    } catch {}

    // Ligatures
    try {
      const { LigaturesAddon } = await import("@xterm/addon-ligatures")
      this.terminal.loadAddon(new LigaturesAddon())
    } catch {}
  }

  dispose(): void {
    this.resizeObserver?.disconnect()
    this.resizeObserver = null
    this.fitAddon = null
    this.terminal?.dispose()
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
    // xterm.js has built-in cursorInactiveStyle: 'outline', so just toggle blink + focus/blur
    this.terminal.options.cursorBlink = focused
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
    if (!this._containerEl || this.resizeObserver) return
    this.resizeObserver = new ResizeObserver(() => {
      this.fitAddon?.fit()
    })
    this.resizeObserver.observe(this._containerEl)
  }

  proposeDimensions(): { cols: number; rows: number } | undefined {
    return this.fitAddon?.proposeDimensions() ?? undefined
  }

  getScreenText(): string {
    if (!this.terminal) return ""
    const buf = this.terminal.buffer.active
    const lines: string[] = []
    for (let y = 0; y < this.terminal.rows; y++) {
      const line = buf.getLine(buf.viewportY + y)
      if (line) lines.push(line.translateToString(true))
    }
    return lines.join("\n")
  }

  input(data: string, wasUserInput: boolean): void {
    // xterm.js doesn't need manual mouse input — built-in mouse support
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
