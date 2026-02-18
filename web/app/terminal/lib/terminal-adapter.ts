// Terminal adapter interface — abstracts ghostty-web vs xterm.js

export interface TerminalConfig {
  fontFamily?: string
  fontSize?: number
  cursorStyle?: "bar" | "block" | "underline"
  cursorBlink?: boolean
  scrollback?: number
  renderer?: RendererType
  theme?: TerminalConfigTheme
}

export interface TerminalConfigTheme {
  foreground?: string
  background?: string
  cursor?: string
  cursorAccent?: string
  selectionBackground?: string
  selectionForeground?: string
  black?: string
  red?: string
  green?: string
  yellow?: string
  blue?: string
  magenta?: string
  cyan?: string
  white?: string
  brightBlack?: string
  brightRed?: string
  brightGreen?: string
  brightYellow?: string
  brightBlue?: string
  brightMagenta?: string
  brightCyan?: string
  brightWhite?: string
}

export interface TerminalAdapter {
  /** One-time global init (e.g. WASM load). Safe to call multiple times. */
  init(): Promise<void>

  /** Create terminal instance with config (does NOT attach to DOM yet). */
  create(config: TerminalConfig): void

  /** Open terminal into a container element. */
  open(container: HTMLDivElement): void

  /** Dispose all resources. */
  dispose(): void

  /** Write data to the terminal. */
  write(data: string | Uint8Array): void

  /** Register handler for user input data. Returns disposer. */
  onData(handler: (data: string) => void): { dispose: () => void }

  /** Register handler for terminal resize. Returns disposer. */
  onResize(handler: (size: { cols: number; rows: number }) => void): { dispose: () => void }

  /** Register handler for title changes (OSC 0/2). Returns disposer. */
  onTitleChange(handler: (title: string) => void): { dispose: () => void }

  /** Focus the terminal. */
  focus(): void

  /** Blur the terminal. */
  blur(): void

  /** Set focused state — controls cursor style (solid vs hollow). */
  setFocused(focused: boolean): void

  /** Fit terminal to container. */
  fit(): void

  /** Start observing container resizes and auto-fitting. */
  observeResize(): void

  /** Propose dimensions based on current container size. */
  proposeDimensions(): { cols: number; rows: number } | undefined

  /** Read the visible screen text. */
  getScreenText(): string

  /** Send raw input to the terminal (for mouse protocol, etc). */
  input(data: string, wasUserInput: boolean): void

  /** Current column count. */
  readonly cols: number

  /** Current row count. */
  readonly rows: number

  /** The container element the terminal is opened in. */
  readonly containerEl: HTMLDivElement | null
}

export type RendererType = "ghostty" | "xterm"

/** Read renderer type from URL param `?renderer=ghostty|xterm`, falling back to
 *  the config-provided default, then "xterm" as the ultimate fallback. */
export function getRendererType(configDefault?: RendererType): RendererType {
  if (typeof window !== "undefined") {
    const params = new URLSearchParams(window.location.search)
    const r = params.get("renderer")
    if (r === "ghostty" || r === "xterm") return r
  }
  return configDefault ?? "xterm"
}

/** Create a TerminalAdapter for the given renderer type. Uses dynamic imports. */
export async function createTerminalAdapter(type: RendererType): Promise<TerminalAdapter> {
  if (type === "xterm") {
    const { XtermAdapter } = await import("./xterm-adapter")
    return new XtermAdapter()
  }
  const { GhosttyAdapter } = await import("./ghostty-adapter")
  return new GhosttyAdapter()
}
