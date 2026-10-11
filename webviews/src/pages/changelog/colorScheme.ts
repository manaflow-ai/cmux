// The color scheme the page paints in: the host theme's (`window.cmuxTheme`, WebTheme.swift: a
// custom Ghostty theme decides it, not the system), else the system's. Media pick their light or
// dark file by it. An external store, read with useSyncExternalStore (no effects).
type ThemeWindow = Window & { cmuxTheme?: { current?: { colorScheme?: string } | null } };

function read(): "light" | "dark" {
  const win = globalThis.window as ThemeWindow | undefined;
  const host = win?.cmuxTheme?.current?.colorScheme;
  if (host === "light" || host === "dark") return host;
  return win?.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function subscribeColorScheme(listener: () => void): () => void {
  const win = globalThis.window;
  if (!win) return () => undefined;
  const media = win.matchMedia?.("(prefers-color-scheme: dark)");
  win.addEventListener("cmux-theme", listener);
  media?.addEventListener?.("change", listener);
  return () => {
    win.removeEventListener("cmux-theme", listener);
    media?.removeEventListener?.("change", listener);
  };
}

export const getColorScheme = read;
