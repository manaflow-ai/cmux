import type { ITheme } from "@xterm/xterm";

const variables = {
  background: "--terminal-background",
  foreground: "--terminal-foreground",
  cursor: "--terminal-cursor",
  selectionBackground: "--selection-bg",
  black: "--ansi-black",
  red: "--ansi-red",
  green: "--ansi-green",
  yellow: "--ansi-yellow",
  blue: "--ansi-blue",
  magenta: "--ansi-magenta",
  cyan: "--ansi-cyan",
  white: "--ansi-white",
  brightBlack: "--ansi-bright-black",
  brightRed: "--ansi-bright-red",
  brightGreen: "--ansi-bright-green",
  brightYellow: "--ansi-bright-yellow",
  brightBlue: "--ansi-bright-blue",
  brightMagenta: "--ansi-bright-magenta",
  brightCyan: "--ansi-bright-cyan",
  brightWhite: "--ansi-bright-white",
} as const satisfies Partial<Record<keyof ITheme, string>>;

export function terminalTheme(element: Element = document.documentElement): ITheme {
  const style = getComputedStyle(element);
  return Object.fromEntries(
    Object.entries(variables).map(([key, variable]) => [key, style.getPropertyValue(variable).trim()]),
  ) as ITheme;
}
