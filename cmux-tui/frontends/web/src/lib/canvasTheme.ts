export function syncCanvasBackground(host: Element, background: string, active: boolean): void {
  if (!active || background.length === 0) return;
  host.closest<HTMLElement>(".app-shell")?.style.setProperty("--terminal-background", background);
}
