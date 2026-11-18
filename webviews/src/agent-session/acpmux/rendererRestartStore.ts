import { useSyncExternalStore } from "react";

/// Why this document loaded, when the app's hung-renderer watchdog ended the chat's renderer and
/// reloaded it: the app's line, already localized ("This chat stopped responding, so cmux restarted
/// it."). The app sets it with a new-document script, before any of the page's own scripts run
/// (PageWebView+Liveness.swift `restartFlagScript`), so the line is read when this module loads and
/// is in the chat's first frame. A script that comes after the pane started calls the hook below.
/// The line stays until the person sends or dismisses it; the script runs once per restart.
export const RENDERER_RESTART_GLOBAL = "__cmuxRendererRestart";
export const RENDERER_RESTART_CHANGED = "__cmuxRendererRestartChanged";

const globals = globalThis as unknown as Record<string, unknown>;
let current: string | undefined;
const listeners = new Set<() => void>();

/// The line in the app's flag; nothing for anything malformed.
export function readRendererRestart(value: unknown): string | undefined {
  if (!value || typeof value !== "object") return undefined;
  const { line } = value as Record<string, unknown>;
  return typeof line === "string" && line ? line : undefined;
}

function set(next: string | undefined): void {
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

/// The documents whose line the person sent or closed. The app's script can come after that (it sets
/// the global again and calls the hook), so the dismissal is kept per document, not in the global.
const dismissedIn = new WeakSet<object>();

/// This document (the module's globals where there is none, as in a test without a DOM).
function thisDocument(): object {
  return typeof document === "undefined" ? globals : document;
}

/// Reads the app's flag now (the module's load, the late script's hook, tests); nothing once this
/// document's line was dismissed.
export function bootRendererRestart(): void {
  if (dismissedIn.has(thisDocument())) return;
  const line = readRendererRestart(globals[RENDERER_RESTART_GLOBAL]);
  if (line) set(line);
}

/// The person sent or closed it: the line goes, and this document does not show it again, even
/// when the app's script runs after this.
export function dismissRendererRestart(): void {
  dismissedIn.add(thisDocument());
  delete globals[RENDERER_RESTART_GLOBAL];
  set(undefined);
}

/// The gallery's reset, which shows several states in one document: no line, and no dismissal, so
/// the next state's boot draws its line. The app never calls it.
export function resetRendererRestart(): void {
  dismissedIn.delete(thisDocument());
  delete globals[RENDERER_RESTART_GLOBAL];
  set(undefined);
}

export function rendererRestartLine(): string | undefined {
  return current;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

export function useRendererRestartLine(): string | undefined {
  return useSyncExternalStore(subscribe, rendererRestartLine, rendererRestartLine);
}

globals[RENDERER_RESTART_CHANGED] = bootRendererRestart;
bootRendererRestart();
