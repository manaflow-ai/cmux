import { UnicodeGraphemesAddon } from "@xterm/addon-unicode-graphemes";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import {
  Terminal,
  type IDisposable,
  type ITheme,
} from "@xterm/xterm";

import type { ShareTerminalAdapter } from "./share-connection";
import {
  CMUX_THEME_OSC,
  decodeXtermThemeMetadata,
  installXtermUserInputForwarder,
  type XtermInputEventSource,
} from "./xterm-compatibility";

const TERMINAL_THEME: ITheme = {
  background: "#0a0a0a",
  foreground: "#ededed",
  cursor: "#ededed",
  cursorAccent: "#0a0a0a",
  selectionBackground: "#2d8cff66",
  selectionInactiveBackground: "#2d8cff33",
  black: "#171717",
  red: "#f87171",
  green: "#4ade80",
  yellow: "#facc15",
  blue: "#60a5fa",
  magenta: "#c084fc",
  cyan: "#22d3ee",
  white: "#e5e5e5",
  brightBlack: "#737373",
  brightRed: "#fca5a5",
  brightGreen: "#86efac",
  brightYellow: "#fde047",
  brightBlue: "#93c5fd",
  brightMagenta: "#d8b4fe",
  brightCyan: "#67e8f9",
  brightWhite: "#ffffff",
};

type XtermPaneOptions = {
  readonly onData: (data: string) => void;
  readonly onBinary: (data: string) => void;
};

/**
 * Browser-only xterm lifecycle. Host rows and columns are never inferred from
 * the browser viewport: xterm keeps the host grid and this controller scales
 * the rendered screen uniformly to the available pane.
 */
export class XtermPaneController implements ShareTerminalAdapter {
  private readonly container: HTMLElement;
  private readonly surface: HTMLDivElement;
  private readonly terminal: Terminal;
  private readonly disposables: IDisposable[] = [];
  private readonly resizeObserver: ResizeObserver;
  private webgl: WebglAddon | null = null;
  private fitFrame: number | null = null;
  private inputEnabled = false;
  private disposed = false;

  constructor(container: HTMLElement, options: XtermPaneOptions) {
    this.container = container;
    this.surface = container.ownerDocument.createElement("div");
    this.surface.className = "cmux-share-xterm-surface";
    container.replaceChildren(this.surface);

    this.terminal = new Terminal({
      // Unicode add-ons are a proposed xterm API in 6.0.0.
      allowProposedApi: true,
      allowTransparency: false,
      altClickMovesCursor: false,
      convertEol: false,
      cursorBlink: true,
      cursorStyle: "block",
      customGlyphs: true,
      disableStdin: true,
      drawBoldTextInBrightColors: true,
      fontFamily:
        '"SFMono-Regular", "SF Mono", "Cascadia Mono", "Liberation Mono", Menlo, monospace',
      fontSize: 13,
      letterSpacing: 0,
      lineHeight: 1,
      macOptionIsMeta: true,
      minimumContrastRatio: 1,
      rescaleOverlappingGlyphs: true,
      rightClickSelectsWord: true,
      screenReaderMode: false,
      scrollback: 10_000,
      smoothScrollDuration: 0,
      theme: TERMINAL_THEME,
    });

    try {
      const graphemes = new UnicodeGraphemesAddon();
      this.terminal.loadAddon(graphemes);
      this.disposables.push(graphemes);
      this.terminal.unicode.activeVersion = "15-graphemes";
    } catch {
      const unicode11 = new Unicode11Addon();
      this.terminal.loadAddon(unicode11);
      this.disposables.push(unicode11);
      this.terminal.unicode.activeVersion = "11";
    }

    this.terminal.open(this.surface);
    this.disposables.push(
      this.terminal.parser.registerOscHandler(CMUX_THEME_OSC, (data) => {
        const theme = decodeXtermThemeMetadata(data);
        if (theme) {
          this.terminal.options.theme = theme;
          return true;
        }
        return data.startsWith("cmux-theme-");
      }),
    );
    const userInput = installXtermUserInputForwarder(
      this.terminal as XtermInputEventSource,
      options.onData,
    );
    if (!userInput) {
      this.terminal.dispose();
      this.surface.remove();
      throw new Error("Pinned xterm user-input hook is unavailable");
    }
    this.disposables.push(
      userInput,
      this.terminal.onBinary(options.onBinary),
    );
    this.enableWebgl();
    this.resizeObserver = new ResizeObserver(() => this.scheduleFit());
    this.resizeObserver.observe(container);
    this.scheduleFit();
  }

  resize(columns: number, rows: number): void {
    if (
      this.disposed ||
      columns === this.terminal.cols &&
        rows === this.terminal.rows
    ) {
      return;
    }
    this.terminal.resize(columns, rows);
    this.scheduleFit();
  }

  write(data: Uint8Array, onConsumed: () => void): void {
    if (this.disposed) {
      onConsumed();
      return;
    }
    this.terminal.write(data, () => {
      this.scheduleFit();
      onConsumed();
    });
  }

  setInputEnabled(enabled: boolean): void {
    if (this.disposed || this.inputEnabled === enabled) return;
    this.inputEnabled = enabled;
    this.terminal.options.disableStdin = !enabled;
    if (!enabled) this.terminal.blur();
  }

  focus(): void {
    if (this.inputEnabled && !this.disposed) this.terminal.focus();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.fitFrame !== null) {
      this.container.ownerDocument.defaultView?.cancelAnimationFrame(
        this.fitFrame,
      );
      this.fitFrame = null;
    }
    this.resizeObserver.disconnect();
    this.webgl?.dispose();
    this.webgl = null;
    for (const disposable of this.disposables.splice(0)) {
      disposable.dispose();
    }
    this.terminal.dispose();
    this.surface.remove();
  }

  private enableWebgl(): void {
    try {
      const addon = new WebglAddon();
      this.terminal.loadAddon(addon);
      this.webgl = addon;
      this.disposables.push(
        addon.onContextLoss(() => {
          if (this.webgl !== addon) return;
          addon.dispose();
          this.webgl = null;
          if (this.terminal.rows > 0) {
            this.terminal.refresh(0, this.terminal.rows - 1);
          }
        }),
      );
    } catch {
      // xterm's built-in renderer remains active when WebGL is unavailable.
      this.webgl = null;
    }
  }

  private scheduleFit(): void {
    if (this.disposed || this.fitFrame !== null) return;
    const ownerWindow = this.container.ownerDocument.defaultView;
    if (!ownerWindow) return;
    this.fitFrame = ownerWindow.requestAnimationFrame(() => {
      this.fitFrame = null;
      this.fitVisual();
    });
  }

  private fitVisual(): void {
    const width = this.container.clientWidth;
    const height = this.container.clientHeight;
    const screen = this.surface.querySelector<HTMLElement>(".xterm-screen");
    if (!screen || width <= 0 || height <= 0) return;
    const screenWidth = screen.offsetWidth;
    const screenHeight = screen.offsetHeight;
    if (screenWidth <= 0 || screenHeight <= 0) return;
    const scale = Math.min(width / screenWidth, height / screenHeight);
    const left = Math.max(0, (width - screenWidth * scale) / 2);
    const top = Math.max(0, (height - screenHeight * scale) / 2);
    this.surface.style.width = `${screenWidth}px`;
    this.surface.style.height = `${screenHeight}px`;
    this.surface.style.transform =
      `translate(${left}px, ${top}px) scale(${scale})`;
  }
}
