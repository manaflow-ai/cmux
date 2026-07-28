import type { IDisposable, ITheme } from "@xterm/xterm";

const THEME_PREFIX = "cmux-theme-v1;";
const MAX_THEME_JSON_BYTES = 12 * 1_024;
const MAX_THEME_BASE64URL_CHARS = 16 * 1_024;
const COLOR = /^#[0-9a-f]{6}$/iu;

export const CMUX_THEME_OSC = 777;

type XtermEvent<T> = (listener: (value: T) => void) => IDisposable;

/**
 * The only private xterm surface cmux depends on. It is pinned to xterm 6.0.0
 * and fails closed if that version-specific user-origin signal disappears.
 */
export interface XtermInputEventSource {
  readonly onData: XtermEvent<string>;
  readonly _core?: {
    readonly coreService?: {
      readonly onUserInput?: XtermEvent<void>;
    };
  };
}

/**
 * Public `onData` mixes user input with parser-generated DA, DSR, OSC query,
 * window, and focus reports. xterm fires its internal `onUserInput` signal
 * synchronously immediately before `onData` only for keyboard, IME, paste, and
 * mouse input. Pairing those events gives the host a single PTY response owner.
 */
export function installXtermUserInputForwarder(
  source: XtermInputEventSource,
  forward: (data: string) => void,
): IDisposable | null {
  const onUserInput = source._core?.coreService?.onUserInput;
  if (typeof onUserInput !== "function") return null;

  let armed = false;
  const userSubscription = onUserInput(() => {
    armed = true;
  });
  const dataSubscription = source.onData((data) => {
    if (!armed) return;
    armed = false;
    forward(data);
  });
  return {
    dispose() {
      armed = false;
      dataSubscription.dispose();
      userSubscription.dispose();
    },
  };
}

type WireTerminalTheme = {
  readonly background: unknown;
  readonly foreground: unknown;
  readonly cursor: unknown;
  readonly cursorText?: unknown;
  readonly selectionBackground: unknown;
  readonly selectionForeground: unknown;
  readonly palette: unknown;
};

function color(value: unknown): value is string {
  return typeof value === "string" && COLOR.test(value);
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function decodeBase64URL(value: string): Uint8Array | null {
  if (
    value.length === 0 ||
    value.length > MAX_THEME_BASE64URL_CHARS ||
    !/^[A-Za-z0-9_-]+$/u.test(value)
  ) {
    return null;
  }
  const standard = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = standard + "=".repeat((4 - standard.length % 4) % 4);
  try {
    const binary = atob(padded);
    if (binary.length > MAX_THEME_JSON_BYTES) return null;
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

/** Maps the host config theme carried in OSC 777 to xterm's reset base. */
export function decodeXtermThemeMetadata(data: string): ITheme | null {
  if (!data.startsWith(THEME_PREFIX)) return null;
  const bytes = decodeBase64URL(data.slice(THEME_PREFIX.length));
  if (!bytes) return null;

  let parsed: Record<string, unknown> | null;
  try {
    parsed = record(JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    ));
  } catch {
    return null;
  }
  if (!parsed) return null;
  const theme = parsed as WireTerminalTheme;
  const palette = Array.isArray(theme.palette) ? theme.palette : null;
  if (
    !color(theme.background) ||
    !color(theme.foreground) ||
    !color(theme.cursor) ||
    !color(theme.selectionBackground) ||
    !color(theme.selectionForeground) ||
    (theme.cursorText !== undefined &&
      theme.cursorText !== null &&
      !color(theme.cursorText)) ||
    !palette ||
    (palette.length !== 16 && palette.length !== 256) ||
    !palette.every(color)
  ) {
    return null;
  }

  const colors = palette as string[];
  return {
    background: theme.background,
    foreground: theme.foreground,
    cursor: theme.cursor,
    cursorAccent: color(theme.cursorText)
      ? theme.cursorText
      : theme.background,
    selectionBackground: theme.selectionBackground,
    selectionForeground: theme.selectionForeground,
    black: colors[0],
    red: colors[1],
    green: colors[2],
    yellow: colors[3],
    blue: colors[4],
    magenta: colors[5],
    cyan: colors[6],
    white: colors[7],
    brightBlack: colors[8],
    brightRed: colors[9],
    brightGreen: colors[10],
    brightYellow: colors[11],
    brightBlue: colors[12],
    brightMagenta: colors[13],
    brightCyan: colors[14],
    brightWhite: colors[15],
    ...(colors.length === 256
      ? { extendedAnsi: colors.slice(16) }
      : {}),
  };
}
