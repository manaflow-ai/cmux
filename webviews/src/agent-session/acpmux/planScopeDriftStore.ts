// The approved plan's scope drift event (`planScopeDrift`, CmuxNextAgentPane): one edit area the
// person can resolve. The host keeps the source of truth and pushes a new value after each action;
// this store only makes an event that arrives before the composer mounts durable.
import { useSyncExternalStore } from "react";

export type PlanScopeDrift = { sessionId: string; path: string; area: string };
type ScopeState = { scope: Set<string>; reported: Set<string>; drift?: PlanScopeDrift };
const states = new Map<string, ScopeState>();
const pendingEdits = new Map<string, Set<string>>();
const listeners = new Set<() => void>();
const notify = () => {
  for (const listener of listeners) listener();
};

function pathOf(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const path = value.replaceAll("\\", "/").replace(/^\.\//, "").trim();
  return path && path !== "." ? path : undefined;
}

function inScope(path: string, scope: string): boolean {
  const normalizedScope = scope.replace(/\/+$/, "");
  if (path === normalizedScope || path.startsWith(`${normalizedScope}/`)) return true;
  return (
    !normalizedScope.startsWith("/") && (path.endsWith(`/${normalizedScope}`) || path.includes(`/${normalizedScope}/`))
  );
}

// Claude Code writes its plan here before it asks for approval: the plan's own file is never drift.
function isPlanFile(path: string): boolean {
  return /(?:^|\/)\.claude\/plans\//.test(path);
}

function areaOf(path: string): string {
  // Absolute ACP locations can have arbitrary workspace prefixes. Use their containing
  // directory as the stable area key so `/Users/a/repo/auth/x.rs` and `/Users/a/repo/auth/y.rs`
  // share one warning without collapsing every absolute location into `Users/`.
  if (path.startsWith("/")) {
    const slash = path.lastIndexOf("/");
    return slash > 0 ? `${path.slice(0, slash)}/` : path;
  }
  const relative = path.replace(/^\/+/, "");
  const slash = relative.indexOf("/");
  return slash < 0 ? relative : `${relative.slice(0, slash)}/`;
}

/** Extract likely file and directory paths from a plan while ignoring prose. */
export function planScopeFromMarkdown(markdown: string): string[] {
  const found = new Set<string>();
  const token =
    /(?:^|[\s(`'"*])((?:\/|\.\.?\/)?[A-Za-z0-9_.@-]+(?:\/[A-Za-z0-9_.@*~-]+)+\/?|[A-Za-z0-9_.@-]+\.[A-Za-z0-9_-]+)(?=$|[\s)`'"*,.:;])/g;
  for (const match of markdown.matchAll(token)) {
    const path = pathOf(match[1]);
    if (!path || path.startsWith("http://") || path.startsWith("https://")) continue;
    found.add(path.replace(/\/(?:\*\/?)+$/, "/"));
  }
  return [...found];
}

export function approvePlan(sessionId: string, markdown: string | undefined): void {
  if (!sessionId || !markdown?.trim()) return;
  const scope = planScopeFromMarkdown(markdown);
  if (!scope.length) return;
  states.set(sessionId, { scope: new Set(scope), reported: new Set() });
  const edits = pendingEdits.get(sessionId);
  if (edits) {
    pendingEdits.delete(sessionId);
    observePlanEdit(sessionId, [...edits]);
  }
  notify();
}

export function clearPlanScope(sessionId: string | undefined): void {
  if (!sessionId) return;
  pendingEdits.delete(sessionId);
  if (states.delete(sessionId)) notify();
}

/** Records edit paths even when the permission decision that approves a plan has not arrived yet. */
export function rememberPlanEdit(sessionId: string, paths: readonly string[]): void {
  if (!sessionId || !paths.length) return;
  if (states.has(sessionId)) {
    observePlanEdit(sessionId, paths);
    return;
  }
  const edits = pendingEdits.get(sessionId) ?? new Set<string>();
  for (const path of paths) {
    if (edits.size >= 128) break;
    const normalized = pathOf(path);
    if (normalized && !isPlanFile(normalized)) edits.add(normalized);
  }
  if (edits.size) pendingEdits.set(sessionId, edits);
}

/** Notes an edit and returns the first new out-of-scope area. */
export function observePlanEdit(sessionId: string, paths: readonly string[]): PlanScopeDrift | undefined {
  const state = states.get(sessionId);
  if (!state) return undefined;
  const named = paths.map(pathOf).filter((path): path is string => !!path && !isPlanFile(path));
  // One edit names one file, often twice (relative and absolute): any spelling in scope covers it.
  if (named.some((path) => [...state.scope].some((scope) => inScope(path, scope)))) return undefined;
  for (const path of named) {
    const area = areaOf(path);
    if (state.reported.has(area)) continue;
    state.reported.add(area);
    state.drift = { sessionId, path, area };
    notify();
    return state.drift;
  }
  return undefined;
}

/** Paths named by an ACP edit call, preferring the agent's relative spelling for the banner. */
export function editPaths(update: unknown): string[] {
  if (!update || typeof update !== "object") return [];
  const value = update as Record<string, unknown>;
  const paths: string[] = [];
  const add = (candidate: unknown) => {
    const path = pathOf(candidate);
    if (path && !paths.includes(path)) paths.push(path);
  };
  const locations = value.locations;
  if (Array.isArray(locations)) {
    for (const location of locations) {
      if (location && typeof location === "object") add((location as Record<string, unknown>).path);
    }
  }
  const content = value.content;
  if (Array.isArray(content)) {
    for (const item of content) {
      if (item && typeof item === "object" && (item as Record<string, unknown>).type === "diff")
        add((item as Record<string, unknown>).path);
    }
  }
  const rawInput = value.rawInput;
  if (rawInput && typeof rawInput === "object") add((rawInput as Record<string, unknown>).file_path);
  return paths;
}

export function keepPlanScopeArea(sessionId: string, area: string): void {
  const state = states.get(sessionId);
  if (!state || !area) return;
  state.scope.add(area.endsWith("/") ? area : `${area}/`);
  state.drift = undefined;
  notify();
}

export function dismissPlanScopeDrift(sessionId: string): void {
  const state = states.get(sessionId);
  if (state?.drift) {
    state.drift = undefined;
    notify();
  }
}

export function currentPlanScopeDrift(sessionId?: string): PlanScopeDrift | undefined {
  return sessionId ? states.get(sessionId)?.drift : undefined;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function usePlanScopeDrift(sessionId?: string): PlanScopeDrift | undefined {
  const read = () => currentPlanScopeDrift(sessionId);
  return useSyncExternalStore(subscribe, read, read);
}

/** Native host pushes remain supported for replay/adoption. */
export function setPlanScopeDrift(value: unknown): void {
  if (!value || typeof value !== "object") return;
  const { sessionId, path, area } = value as Record<string, unknown>;
  if (typeof sessionId !== "string" || typeof path !== "string" || typeof area !== "string") return;
  const state = states.get(sessionId) ?? { scope: new Set<string>(), reported: new Set<string>() };
  state.drift = { sessionId, path, area };
  states.set(sessionId, state);
  notify();
}
