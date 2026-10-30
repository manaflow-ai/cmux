import { createContext, useCallback, useContext, useState, useSyncExternalStore, type ReactNode } from "react";
import { useTranscriptView, type TranscriptView } from "./transcriptView";

/**
 * Disclosure state for transcript details. Rows are virtualized, so the state cannot live in a
 * component's local `useState`: a command that scrolls out of the viewport would forget whether
 * the reader opened it. The key is the acpmux session plus a stable tool or group id.
 */
const STORAGE_KEY = "cmux.acpmux.transcriptDisclosure";
const SESSION_LIMIT = 40;
const DISCLOSURE_LIMIT = 600;
const DEFAULT_SESSION = "__transcript__";

type SessionChoices = Map<string, boolean>;
type Choices = Map<string, SessionChoices>;

let choices: Choices | undefined;
const listeners = new Set<() => void>();

function parseChoices(value: unknown): Choices {
  const result: Choices = new Map();
  if (!value || typeof value !== "object") return result;
  for (const [sessionId, rawSession] of Object.entries(value as Record<string, unknown>)) {
    if (!rawSession || typeof rawSession !== "object") continue;
    const session = new Map<string, boolean>();
    for (const [key, rawValue] of Object.entries(rawSession as Record<string, unknown>)) {
      if (typeof rawValue === "boolean") session.set(key, rawValue);
    }
    if (session.size) result.set(sessionId, session);
  }
  return result;
}

function load(): Choices {
  if (choices) return choices;
  try {
    choices = parseChoices(JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "null"));
  } catch {
    // Private windows, test DOMs and full storage fall back to the in-memory map.
    choices = new Map();
  }
  return choices;
}

function storageValue(): Record<string, Record<string, boolean>> {
  return Object.fromEntries([...load()].map(([sessionId, session]) => [sessionId, Object.fromEntries(session)]));
}

function notify(): void {
  for (const listener of listeners) listener();
}

function save(sessionId: string, key: string, value: boolean): void {
  const all = load();
  let session = all.get(sessionId);
  if (!session) all.set(sessionId, (session = new Map()));
  session.delete(key);
  session.set(key, value);
  while (session.size > DISCLOSURE_LIMIT) session.delete(session.keys().next().value!);
  while (all.size > SESSION_LIMIT) all.delete(all.keys().next().value!);
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(storageValue()));
  } catch {
    // The in-memory choice still lasts for this page when storage is unavailable.
  }
  notify();
}

function read(sessionId: string, key: string): boolean | undefined {
  return load().get(sessionId)?.get(key);
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

const DisclosureSession = createContext<string>(DEFAULT_SESSION);
/** The chat's transcript view (transcriptView.ts), read once here for every row under it. */
const ViewContext = createContext<TranscriptView>("normal");

/// The chat a transcript's disclosure id belongs to, whose view the chat menu sets: a subagent's
/// transcript (`<chat>:subagent:<id>`) and a replay (`replay:<chat>`) follow their chat's view.
export function viewChat(sessionId: string | undefined): string | undefined {
  if (!sessionId) return undefined;
  const chat = sessionId.startsWith("replay:") ? sessionId.slice("replay:".length) : sessionId;
  const subagent = chat.indexOf(":subagent:");
  return subagent < 0 ? chat : chat.slice(0, subagent);
}

export function TranscriptDisclosureProvider({ sessionId, children }: { sessionId?: string; children: ReactNode }) {
  const view = useTranscriptView(viewChat(sessionId));
  return (
    <DisclosureSession.Provider value={sessionId || DEFAULT_SESSION}>
      <ViewContext.Provider value={view}>{children}</ViewContext.Provider>
    </DisclosureSession.Provider>
  );
}

/** The chat's transcript view: Normal, Thinking (thoughts open) or Verbose (tool output open too). */
export const useTranscriptViewContext = (): TranscriptView => useContext(ViewContext);

export type DisclosureSetter = (value: boolean | ((current: boolean) => boolean)) => void;

/**
 * Returns a persisted disclosure value and a React-compatible setter. `verboseOpen` opens it by
 * default in the Verbose view (a tool's output). The reader's toggles are kept per view, so each
 * view starts from its own defaults and switching back finds the old toggles where they were.
 */
export function useTranscriptDisclosure(
  key: string,
  defaultOpen = false,
  verboseOpen = false,
): [boolean, DisclosureSetter] {
  const view = useContext(ViewContext);
  const chat = useContext(DisclosureSession);
  const sessionId = view === "normal" ? chat : `${chat}#${view}`;
  const opens = defaultOpen || (verboseOpen && view === "verbose");
  const getSnapshot = useCallback(() => read(sessionId, key) ?? opens, [sessionId, key, opens]);
  const open = useSyncExternalStore(subscribe, getSnapshot, () => opens);
  const setOpen = useCallback<DisclosureSetter>(
    (value) => {
      const current = read(sessionId, key) ?? opens;
      save(sessionId, key, typeof value === "function" ? value(current) : value);
    },
    [sessionId, key, opens],
  );
  return [open, setOpen];
}

/**
 * A lone call's details: closed, or open in the Verbose view. In Normal the choice is the row's own,
 * kept while it is mounted, as before the views. In Thinking and Verbose it is kept per view in the
 * session's disclosures under `key` (the call's id), so a row drawn again finds it.
 */
export function useRowDisclosure(key: string | undefined): [boolean, (open: boolean) => void] {
  const view = useContext(ViewContext);
  const [mounted, setMounted] = useState(false);
  const [kept, setKept] = useTranscriptDisclosure(key ? `row:${key}` : "", false, true);
  const persists = view !== "normal" && key !== undefined;
  const setOpen = useCallback((next: boolean) => (persists ? setKept(next) : setMounted(next)), [persists, setKept]);
  return [persists ? kept : mounted, setOpen];
}

/** Test/gallery reset; production callers keep each session's choices. */
export function resetTranscriptDisclosure(sessionId?: string): void {
  if (sessionId) {
    // With the views' own toggles (`session#view`).
    for (const id of load().keys()) if (id === sessionId || id.startsWith(`${sessionId}#`)) load().delete(id);
  } else choices = new Map();
  try {
    if (sessionId) globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(storageValue()));
    else globalThis.localStorage?.removeItem(STORAGE_KEY);
  } catch {
    // Nothing to persist.
  }
  notify();
}
