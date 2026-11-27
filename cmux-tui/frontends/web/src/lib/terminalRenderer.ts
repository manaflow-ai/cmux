/** Which terminal renderer a page uses. `default` keeps today's choice (the
 * render model on protocol 7+, else xterm.js bytes); `ghostty` renders the
 * byte stream with ghostty-web, Ghostty's VT core in wasm (RFD 0083 step 4).
 * Opt-in with `?terminal=ghostty`; nothing changes without it. */
export type TerminalRendererChoice = "default" | "ghostty";

export function terminalRendererChoice(search: string): TerminalRendererChoice {
  return new URLSearchParams(search).get("terminal")?.trim().toLowerCase() === "ghostty" ? "ghostty" : "default";
}
